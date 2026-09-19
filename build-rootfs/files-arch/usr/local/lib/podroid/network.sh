#!/bin/sh
# podroid-network.sh — ArchDroid networking (systemd oneshot).
# Faithful port of the podroid-network OpenRC service start() body:
# QEMU/TCG uses the static SLIRP addressing; AVF uses DHCP. Extra safety
# vs the original: the AVF branch falls back to dhcpcd (Arch base ships no
# udhcpc applet links), then the shared post-check decides success.
# Markers preserved verbatim for the app boot detector: "Network found",
# "DNS: ...", plus "IP: <addr>" for the build-all.sh boot test.

echo "Configuring containers..." > /dev/console
ip link set lo up 2>/dev/null
NETIF=""
for _i in $(seq 1 10); do
    # Exclude virtual/bridge devices so the real virtio NIC is picked.
    NETIF=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | \
        grep -vE '^(lo|dummy[0-9]*|veth|podman|cni|docker|lxcbr|br-)' | head -1)
    [ -n "$NETIF" ] && break
    sleep 0.05
done
if [ -z "$NETIF" ]; then
    echo "podroid-network: no network interface" > /dev/console
    exit 1
fi
ip link set "$NETIF" up

GUEST_IP=""
if grep -q 'podroid\.backend=avf' /proc/cmdline 2>/dev/null; then
    # AVF backend: crosvm wires the guest to a TAP that Android's tethering
    # manager runs DHCP on. Prefer udhcpc when present, else dhcpcd (both
    # apply the lease incl. DNS; belt-and-suspenders resolv.conf below).
    udhcpc -i "$NETIF" -t 8 -T 1 -A 1 -q -f -n 2>/dev/null || \
        udhcpc -i "$NETIF" -q -f -n 2>/dev/null || \
        { command -v dhcpcd >/dev/null 2>&1 && dhcpcd -4 -w -t 20 "$NETIF" 2>/dev/null; } || true
    # Belt-and-suspenders: if DHCP didn't write resolv.conf, drop public DNS.
    [ -s /etc/resolv.conf ] || printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
    # Don't report success on a total DHCP failure.
    if ! ip -o -4 addr show dev "$NETIF" 2>/dev/null | grep -q 'inet '; then
        echo "podroid-network: DHCP did not assign an address to $NETIF" > /dev/console
        exit 1
    fi
    GUEST_IP=$(ip -o -4 addr show dev "$NETIF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
else
    # QEMU/TCG backend: static SLIRP addressing (faster + matches existing
    # setups). SLIRP's 10.0.2.3 DNS forwarder is dead on Android, so prefer
    # the device's own resolver passed via podroid.dns= when valid.
    ip addr add 10.0.2.15/24 dev "$NETIF" 2>/dev/null
    ip route add default via 10.0.2.2 dev "$NETIF" 2>/dev/null
    DNS_RAW=$(sed -n 's/.*podroid\.dns=\([0-9.,]*\).*/\1/p' /proc/cmdline 2>/dev/null)
    DEVICE_DNS=""
    if [ -n "$DNS_RAW" ]; then
        _ifs=$IFS
        IFS=,
        set -- $DNS_RAW
        IFS=$_ifs
        for _cand in "$@"; do
            _dots=$IFS
            IFS=.
            set -- $_cand
            IFS=$_dots
            if [ $# -eq 4 ]; then
                _ok=1
                for _o in "$1" "$2" "$3" "$4"; do
                    case "$_o" in ''|*[!0-9]*) _ok=0 ;; esac
                    if [ "$_ok" = 1 ] && [ "$_o" -gt 255 ] 2>/dev/null; then
                        _ok=0
                    fi
                done
                if [ "$_ok" = 1 ]; then
                    DEVICE_DNS="$_cand"
                    break
                fi
            fi
        done
    fi
    if [ -n "$DEVICE_DNS" ]; then
        printf 'nameserver %s\nnameserver 8.8.8.8\nnameserver 1.1.1.1\n' "$DEVICE_DNS" \
            > /etc/resolv.conf
    else
        printf 'nameserver 10.0.2.3\nnameserver 8.8.8.8\nnameserver 1.1.1.1\n' \
            > /etc/resolv.conf
    fi
    echo "DNS: ${DEVICE_DNS:-10.0.2.3} 8.8.8.8" > /dev/console
    # Mirror the AVF post-check: if the static assignment didn't stick,
    # don't report success.
    if ! ip -o -4 addr show dev "$NETIF" 2>/dev/null | grep -q 'inet '; then
        echo "podroid-network: static IP did not stick on $NETIF" > /dev/console
        exit 1
    fi
    GUEST_IP="10.0.2.15"
fi
BW_MBIT=$(sed -n 's/.*podroid\.bandwidth=\([0-9]*\).*/\1/p' /proc/cmdline 2>/dev/null)
if [ -n "$BW_MBIT" ] && [ "$BW_MBIT" -gt 0 ]; then
    tc qdisc replace dev "$NETIF" root tbf rate "${BW_MBIT}mbit" burst 32kbit latency 400ms 2>/dev/null || true
fi
[ -n "$GUEST_IP" ] && echo "IP: $GUEST_IP" > /dev/console
echo "Network found" > /dev/console
exit 0

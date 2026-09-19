#!/bin/sh
# lxcbr0.sh — ArchDroid LXC bridge setup (run by podroid-lxcbr0.service).
# Faithful port of the dnsmasq.lxcbr0 OpenRC service start() body: creates
# lxcbr0 (10.0.3.1/24), installs the MASQUERADE rule, and launches dnsmasq
# for DHCP. iproute2 is preferred; brctl kept as a fallback if present.
# dnsmasq daemonizes itself and writes its pidfile (Type=forking in unit).

ip link show lxcbr0 >/dev/null 2>&1 || brctl addbr lxcbr0 2>/dev/null || ip link add lxcbr0 type bridge
ip addr add 10.0.3.1/24 dev lxcbr0 2>/dev/null || true
ip link set lxcbr0 up
iptables -t nat -C POSTROUTING -s 10.0.3.0/24 ! -d 10.0.3.0/24 -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s 10.0.3.0/24 ! -d 10.0.3.0/24 -j MASQUERADE
exec /usr/bin/dnsmasq \
    --interface=lxcbr0 --except-interface=lo \
    --bind-interfaces --dhcp-range=10.0.3.2,10.0.3.254,12h \
    --pid-file=/run/dnsmasq.lxcbr0.pid

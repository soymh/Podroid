#!/bin/sh
# build-rootfs-arch.sh — customize a pacstrap'd Arch rootfs into a Podroid image.
# Mirrors build-rootfs.sh: no chroot (x86_64 host can't exec aarch64 bins
# without extra setup), so all runlevel wiring is done via direct symlinks.
set -eu
: "${ROOTFS:=/work/rootfs}"

mkdir -p "$ROOTFS/etc"
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "$ROOTFS/etc/resolv.conf"

# Apply file capabilities to newuidmap/newgidmap so the squashfs ships with
# the correct security.capability xattr (preserved by mksquashfs without -no-xattrs).
if command -v setcap >/dev/null 2>&1; then
    setcap cap_setuid+ep "$ROOTFS/usr/bin/newuidmap" 2>/dev/null || true
    setcap cap_setgid+ep "$ROOTFS/usr/bin/newgidmap" 2>/dev/null || true
fi

# Ensure sudo is setuid-root (pacman usually does this; overlay builders can drop it).
chmod u+s "$ROOTFS/usr/bin/sudo" 2>/dev/null || true

# sudo: wheel group can become root (Arch convention; parallels Alpine doas/sudo rules).
mkdir -p "$ROOTFS/etc/sudoers.d"
echo "%wheel ALL=(ALL) ALL" > "$ROOTFS/etc/sudoers.d/wheel"
chmod 0440 "$ROOTFS/etc/sudoers.d/wheel"

# Set root password to "podroid" (pre-hashed with openssl).
# We can't run chpasswd inside the aarch64 rootfs from an x86_64 host,
# so write the SHA-512 hash directly into /etc/shadow.
ROOT_HASH=$(openssl passwd -6 podroid)
sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" "$ROOTFS/etc/shadow"

# Strip docs/man/locale to shrink squashfs.
rm -rf "$ROOTFS/usr/share/man" "$ROOTFS/usr/share/doc" \
       "$ROOTFS/usr/share/locale" "$ROOTFS/usr/share/info"

# Remove the stock pulseaudio OpenRC service if the AUR set shipped one.
# Podroid starts pulseaudio directly from podroid-x11 (start-stop-daemon).
rm -f "$ROOTFS/etc/init.d/pulseaudio"

# Pre-create podman storage dirs (saves first-boot mkdir).
mkdir -p "$ROOTFS/var/lib/containers/storage" \
         "$ROOTFS/run/containers/storage" \
         "$ROOTFS/run/libpod" \
         "$ROOTFS/run/crun"

# Copy Podroid OpenRC services (shared with Alpine).
cp /work/files/etc/init.d/podroid-bootstrap "$ROOTFS/etc/init.d/"
cp /work/files/etc/init.d/podroid-network   "$ROOTFS/etc/init.d/"
cp /work/files/etc/init.d/podroid-resize    "$ROOTFS/etc/init.d/"
cp /work/files/etc/init.d/podroid-ready     "$ROOTFS/etc/init.d/"
cp /work/files/etc/init.d/podroid-x11       "$ROOTFS/etc/init.d/"
cp /work/files/etc/init.d/podroid-vsock     "$ROOTFS/etc/init.d/"
cp /work/files/etc/init.d/podroid-hostd     "$ROOTFS/etc/init.d/"
cp /work/files/etc/init.d/podroid-downloads "$ROOTFS/etc/init.d/"
cp /work/files/etc/init.d/podroid-migrate   "$ROOTFS/etc/init.d/"
chmod +x "$ROOTFS/etc/init.d/podroid-"*

# Minimal OpenRC wrappers for Arch-native daemons (same openrc-run style as
# podroid-* scripts). Arch has no docker-openrc / lxc-openrc / dropbear-openrc
# splits, so we ship tiny equivalents here instead of in files/ (keeps the
# Alpine tree untouched).
cat > "$ROOTFS/etc/init.d/docker" <<'EOF'
#!/sbin/openrc-run
description="Docker daemon"
command="/usr/bin/dockerd"
command_args="--iptables=true --ip6tables=true"
pidfile="/run/docker.pid"
depend() {
    need podroid-network
    after podroid-bootstrap
}
EOF
cat > "$ROOTFS/etc/init.d/sshd" <<'EOF'
#!/sbin/openrc-run
description="OpenSSH server"
command="/usr/bin/sshd"
command_args="-D"
pidfile="/run/sshd.pid"
depend() {
    need podroid-network
}
start_pre() {
    [ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A
}
EOF
cat > "$ROOTFS/etc/init.d/lxc" <<'EOF'
#!/sbin/openrc-run
description="LXC container autostart"
command="/usr/bin/lxc-autostart"
command_args=""
depend() {
    need podroid-network
    after docker
}
start() {
    ebegin "Starting LXC autostart containers"
    lxc-autostart -a 2>/dev/null || true
    eend 0
}
stop() {
    ebegin "Stopping LXC containers"
    lxc-autostart -s 2>/dev/null || true
    eend 0
}
EOF
cat > "$ROOTFS/etc/init.d/dnsmasq.lxcbr0" <<'EOF'
#!/sbin/openrc-run
description="LXC bridge (lxcbr0, 10.0.3.1/24) + NAT/DHCP"
depend() {
    need podroid-network
    before lxc
}
start() {
    ebegin "Setting up lxcbr0"
    ip link show lxcbr0 >/dev/null 2>&1 || brctl addbr lxcbr0 2>/dev/null || ip link add lxcbr0 type bridge
    ip addr add 10.0.3.1/24 dev lxcbr0 2>/dev/null || true
    ip link set lxcbr0 up
    iptables -t nat -C POSTROUTING -s 10.0.3.0/24 ! -d 10.0.3.0/24 -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s 10.0.3.0/24 ! -d 10.0.3.0/24 -j MASQUERADE
    start-stop-daemon --start --quiet --pidfile /run/dnsmasq.lxcbr0.pid --exec /usr/bin/dnsmasq -- \
        --interface=lxcbr0 --except-interface=lo \
        --bind-interfaces --dhcp-range=10.0.3.2,10.0.3.254,12h \
        --pid-file=/run/dnsmasq.lxcbr0.pid || true
    eend 0
}
stop() {
    start-stop-daemon --stop --quiet --pidfile /run/dnsmasq.lxcbr0.pid || true
    return 0
}
EOF
chmod +x "$ROOTFS/etc/init.d/docker" "$ROOTFS/etc/init.d/sshd" \
         "$ROOTFS/etc/init.d/lxc" "$ROOTFS/etc/init.d/dnsmasq.lxcbr0"

# Copy /usr/local/bin helpers.
mkdir -p "$ROOTFS/usr/local/bin"
cp /work/files/usr/local/bin/podroid-resize "$ROOTFS/usr/local/bin/"
cp /work/files/usr/local/bin/podroid-login  "$ROOTFS/usr/local/bin/"
cp /work/files/usr/local/bin/podroid-getty  "$ROOTFS/usr/local/bin/"
cp /work/files/usr/local/bin/podroid-backup "$ROOTFS/usr/local/bin/"
cp /work/files/usr/local/bin/podroid-update-stats "$ROOTFS/usr/local/bin/"
chmod +x "$ROOTFS/usr/local/bin/podroid-vsock-agent" 2>/dev/null || true
chmod +x "$ROOTFS/usr/local/bin/podroid-hostd" 2>/dev/null || true
chmod +x "$ROOTFS/usr/local/bin/podroid-overlay-normalize" 2>/dev/null || true
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-notify"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-forward"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-open"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-power"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-headless"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-server"
chmod +x "$ROOTFS/usr/local/bin/podroid-"*
mkdir -p "$ROOTFS/etc/conf.d"
cp /work/files/etc/conf.d/podroid "$ROOTFS/etc/conf.d/"
mkdir -p "$ROOTFS/etc/podroid"
cp /work/files/etc/podroid/forwards.conf "$ROOTFS/etc/podroid/forwards.conf"
chmod 0644 "$ROOTFS/etc/podroid/forwards.conf"
mkdir -p "$ROOTFS/etc/podroid/migrations"
cp /work/files/etc/podroid/migrations/README "$ROOTFS/etc/podroid/migrations/README"
# System-version stamp: the migration anchor (same as Alpine).
printf '%s\n' "${SYSTEM_VERSION:-0}" > "$ROOTFS/etc/podroid/system-version"
chmod 0644 "$ROOTFS/etc/podroid/system-version"
cp /work/files/etc/inittab "$ROOTFS/etc/inittab"
cp /work/files/etc/rc.conf "$ROOTFS/etc/rc.conf"

# /etc/profile.d helpers (same as Alpine).
mkdir -p "$ROOTFS/etc/profile.d"
cp /work/files/etc/profile.d/podroid-color.sh "$ROOTFS/etc/profile.d/"
cp /work/files/etc/profile.d/podroid-x11.sh   "$ROOTFS/etc/profile.d/"
chmod 0644 "$ROOTFS/etc/profile.d/podroid-color.sh" "$ROOTFS/etc/profile.d/podroid-x11.sh"

# /etc/containers/storage.conf — pin Podman to in-kernel overlay.
mkdir -p "$ROOTFS/etc/containers"
cp /work/files/etc/containers/storage.conf "$ROOTFS/etc/containers/storage.conf"
chmod 0644 "$ROOTFS/etc/containers/storage.conf"

# Hostname.
echo "podroid" > "$ROOTFS/etc/hostname"
echo "127.0.0.1 localhost podroid" > "$ROOTFS/etc/hosts"
echo "::1 localhost ip6-localhost" >> "$ROOTFS/etc/hosts"

# Login banner.
cat > "$ROOTFS/etc/issue" <<'EOF'
Welcome to Podroid (Arch Linux)
Kernel \r on \m (\l)

  Default login:  root  /  podroid
  Change root password:    passwd
  Create a regular user:   useradd -G wheel <name>
                           (wheel group → can run sudo)

EOF

# Set runlevels via direct symlinks (can't chroot into aarch64 rootfs to run rc-update).
mkdir -p "$ROOTFS/etc/runlevels/default" "$ROOTFS/etc/runlevels/boot"
for svc in podroid-migrate podroid-bootstrap podroid-network podroid-resize sshd docker lxc dnsmasq.lxcbr0 podroid-x11 podroid-vsock podroid-downloads podroid-hostd podroid-ready; do
    if [ -e "$ROOTFS/etc/init.d/$svc" ]; then
        ln -sf "/etc/init.d/$svc" "$ROOTFS/etc/runlevels/default/$svc"
    else
        echo "WARN: init script /etc/init.d/$svc missing, skipping runlevel symlink"
    fi
done

# Disable services we don't need (initramfs already handles them, or they're noise in the VM).
for svc in hwclock swclock urandom networking sysctl bootmisc syslog keymaps; do
    rm -f "$ROOTFS/etc/runlevels/boot/$svc" "$ROOTFS/etc/runlevels/default/$svc"
done

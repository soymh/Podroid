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

# Set root password to "archdroid" (ArchDroid's counterpart to Alpine's
# "podroid"). Pre-hashed: we can't run chpasswd inside the aarch64 rootfs
# from an x86_64 host, so write the SHA-512 hash directly into /etc/shadow.
ROOT_HASH=$(openssl passwd -6 archdroid)
sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" "$ROOTFS/etc/shadow"

# Strip docs/man/locale to shrink squashfs.
rm -rf "$ROOTFS/usr/share/man" "$ROOTFS/usr/share/doc" \
       "$ROOTFS/usr/share/locale" "$ROOTFS/usr/share/info"

# AUR openrc uses sysconfdir=/etc/openrc (avoids clashing with other init
# systems): init scripts live in /etc/openrc/init.d, runlevels in
# /etc/openrc/runlevels, rc.conf in /etc/openrc/rc.conf. All OpenRC paths
# below go through $OERC. (/sbin/openrc* shebangs/paths still resolve via
# the /sbin -> /usr/bin usrmerge symlink; /etc/inittab stays at /etc
# because busybox init reads it there.)
OERC="$ROOTFS/etc/openrc"
mkdir -p "$OERC/init.d"

# Remove the stock pulseaudio OpenRC service if one was shipped.
# Podroid starts pulseaudio directly from podroid-x11 (start-stop-daemon).
rm -f "$OERC/init.d/pulseaudio"

# Pre-create podman storage dirs (saves first-boot mkdir).
mkdir -p "$ROOTFS/var/lib/containers/storage" \
         "$ROOTFS/run/containers/storage" \
         "$ROOTFS/run/libpod" \
         "$ROOTFS/run/crun"

# Copy Podroid OpenRC services (shared with Alpine).
cp /work/files/etc/init.d/podroid-bootstrap "$OERC/init.d/"
cp /work/files/etc/init.d/podroid-network   "$OERC/init.d/"
cp /work/files/etc/init.d/podroid-resize    "$OERC/init.d/"
cp /work/files/etc/init.d/podroid-ready     "$OERC/init.d/"
cp /work/files/etc/init.d/podroid-x11       "$OERC/init.d/"
cp /work/files/etc/init.d/podroid-vsock     "$OERC/init.d/"
cp /work/files/etc/init.d/podroid-hostd     "$OERC/init.d/"
cp /work/files/etc/init.d/podroid-downloads "$OERC/init.d/"
cp /work/files/etc/init.d/podroid-migrate   "$OERC/init.d/"
chmod +x "$OERC/init.d/podroid-"*

# Minimal OpenRC wrappers for Arch-native daemons (same openrc-run style as
# podroid-* scripts). Arch has no docker-openrc / lxc-openrc / dropbear-openrc
# splits, so we ship tiny equivalents here instead of in files/ (keeps the
# Alpine tree untouched).
cat > "$OERC/init.d/docker" <<'EOF'
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
cat > "$OERC/init.d/sshd" <<'EOF'
#!/sbin/openrc-run
description="OpenSSH server"
# NOTE: no -D flag: like the reference openrc-arch-services script, let sshd
# daemonize itself so it writes /run/sshd.pid (with -D the pidfile is never
# written and OpenRC can't track the service).
command="/usr/bin/sshd"
pidfile="/run/sshd.pid"
depend() {
    need podroid-network
}
start_pre() {
    # Privilege separation dir: normally created by systemd-tmpfiles, which
    # doesn't exist under OpenRC — without it sshd refuses to start.
    mkdir -p /run/sshd
    chmod 0755 /run/sshd
    [ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A
}
EOF
cat > "$OERC/init.d/lxc" <<'EOF'
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
cat > "$OERC/init.d/dnsmasq.lxcbr0" <<'EOF'
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
chmod +x "$OERC/init.d/docker" "$OERC/init.d/sshd" \
         "$OERC/init.d/lxc" "$OERC/init.d/dnsmasq.lxcbr0"

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
mkdir -p "$ROOTFS/etc/podroid"
cp /work/files/etc/podroid/forwards.conf "$ROOTFS/etc/podroid/forwards.conf"
chmod 0644 "$ROOTFS/etc/podroid/forwards.conf"
mkdir -p "$ROOTFS/etc/podroid/migrations"
cp /work/files/etc/podroid/migrations/README "$ROOTFS/etc/podroid/migrations/README"
# Install every migration script (mirrors Alpine's build-rootfs.sh loop, which
# upstream's refactor introduced alongside migrations/33.sh): a new migration
# needs no build-script edit. NOTE: no conf.d handling here — upstream removed
# files/etc/conf.d/podroid as unused (nothing reads conf.d), so there is
# nothing to copy on either distro.
for f in /work/files/etc/podroid/migrations/*.sh; do
    [ -f "$f" ] || continue
    cp "$f" "$ROOTFS/etc/podroid/migrations/"
    chmod 0755 "$ROOTFS/etc/podroid/migrations/$(basename "$f")"
done
# System-version stamp: the migration anchor (same as Alpine).
printf '%s\n' "${SYSTEM_VERSION:-0}" > "$ROOTFS/etc/podroid/system-version"
chmod 0644 "$ROOTFS/etc/podroid/system-version"
cp /work/files/etc/inittab "$ROOTFS/etc/inittab"
cp /work/files/etc/rc.conf "$OERC/rc.conf"
# SSH auth drop-in (Arch default rejects root+password; see the file).
mkdir -p "$ROOTFS/etc/ssh/sshd_config.d"
cp /work/files/etc/ssh/sshd_config.d/podroid.conf "$ROOTFS/etc/ssh/sshd_config.d/podroid.conf"
chmod 0644 "$ROOTFS/etc/ssh/sshd_config.d/podroid.conf"

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

  Default login:  root  /  archdroid
  Change root password:    passwd
  Create a regular user:   useradd -G wheel <name>
                           (wheel group → can run sudo)

EOF

# Set runlevels via direct symlinks (can't chroot into aarch64 rootfs to run rc-update).
mkdir -p "$OERC/runlevels/default" "$OERC/runlevels/boot"
for svc in podroid-migrate podroid-bootstrap podroid-network podroid-resize sshd docker lxc dnsmasq.lxcbr0 podroid-x11 podroid-vsock podroid-downloads podroid-hostd podroid-ready; do
    if [ -e "$OERC/init.d/$svc" ]; then
        ln -sf "/etc/openrc/init.d/$svc" "$OERC/runlevels/default/$svc"
    else
        echo "WARN: init script /etc/openrc/init.d/$svc missing, skipping runlevel symlink"
    fi
done

# Disable services we don't need (initramfs already handles them, or they're noise in the VM).
for svc in hwclock swclock urandom networking sysctl bootmisc syslog keymaps; do
    rm -f "$OERC/runlevels/boot/$svc" "$OERC/runlevels/default/$svc"
done

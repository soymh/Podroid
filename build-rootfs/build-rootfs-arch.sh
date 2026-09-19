#!/bin/sh
# build-rootfs-arch.sh — customize an ArchLinuxARM rootfs into a Podroid image.
# ArchDroid boots systemd (stock units + files-arch units below). No chroot
# (x86_64 host can't exec aarch64 bins without extra setup), so unit enabling
# is done via direct symlinks — exactly what `systemctl enable` does.
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

# Podroid bring-up lives in files-arch as systemd units + lib scripts (no
# OpenRC ships on this image anymore): install both here, enable below.
SYSU="$ROOTFS/etc/systemd/system"
mkdir -p "$SYSU" "$ROOTFS/usr/local/lib/podroid"
cp /work/files-arch/etc/systemd/system/podroid-*.service "$SYSU/"
cp /work/files-arch/usr/local/lib/podroid/*.sh "$ROOTFS/usr/local/lib/podroid/"
chmod 0644 "$SYSU"/podroid-*.service
chmod +x "$ROOTFS/usr/local/lib/podroid/"*.sh
mkdir -p "$SYSU/serial-getty@.service.d"
cp /work/files-arch/etc/systemd/system/serial-getty@.service.d/podroid.conf \
    "$SYSU/serial-getty@.service.d/podroid.conf"
chmod 0644 "$SYSU/serial-getty@.service.d/podroid.conf"

# Pre-create podman storage dirs (saves first-boot mkdir).
mkdir -p "$ROOTFS/var/lib/containers/storage" \
         "$ROOTFS/run/containers/storage" \
         "$ROOTFS/run/libpod" \
         "$ROOTFS/run/crun"

# Enable units via direct symlinks — the same no-chroot technique the old
# OpenRC runlevels used (`systemctl enable` is symlink creation underneath).
# Stock units used as-shipped: sshd (+sshdgenkeys for first-boot host keys),
# docker, lxc. Everything else is ours from files-arch.
wants="$SYSU/multi-user.target.wants"
mkdir -p "$wants"
for unit in podroid-migrate.service podroid-bootstrap.service podroid-network.service \
    podroid-resize.service podroid-hostd.service podroid-vsock.service \
    podroid-downloads.service podroid-xvnc.service podroid-pulse.service \
    podroid-lxcbr0.service podroid-ready.service \
    sshd.service sshdgenkeys.service docker.service lxc.service; do
    ln -sf "../$unit" "$wants/$unit"
done
# getty instances for both ttys (podroid-getty picks via podroid.tty=).
mkdir -p "$SYSU/getty.target.wants"
for tty in hvc0 ttyS0; do
    ln -sf "/usr/lib/systemd/system/serial-getty@.service" "$SYSU/getty.target.wants/serial-getty@$tty.service"
done
# Default boot target: multi-user (no display manager in the VM).
ln -sf "/usr/lib/systemd/system/multi-user.target" "$SYSU/default.target"
# Silence stock getty@tty1 (no tty1 console here; would sit failed forever).
ln -sf /dev/null "$SYSU/getty@tty1.service"

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
# NOTE: inittab/rc.conf are OpenRC artifacts, inert under systemd — copied
# for provenance, never read. Boot target comes from the default.target
# symlink wired above.
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

#!/bin/sh
# podroid-ready.sh — ArchDroid ready marker (systemd oneshot, last).
# Faithful port of the podroid-ready OpenRC service start() body. By the time
# this runs, every other unit has started (After= list in the unit).
# Markers below are consumed by the Android boot detector — keep verbatim.

# OOM-protect Podroid's infrastructure processes so a hungry user app
# (Firefox, big npm builds, podman pulls) gets reaped first. -1000 makes a
# process immune to OOM. Match by argv[0] basename to catch all variants
# (multiple Xvnc screens, forked sshd instances, agent listener children).
for _name in sshd Xvnc pulseaudio podroid-vsock-agent dnsmasq; do
    for _pid in $(pgrep -x "$_name" 2>/dev/null); do
        echo -1000 > "/proc/$_pid/oom_score_adj" 2>/dev/null
    done
done

# Emit the boot stages PodroidQemu.detectBootStage() expects.
if [ -x /usr/local/bin/podroid-update-stats ]; then
    /usr/local/bin/podroid-update-stats || true
fi
echo "Starting SSH..." > /dev/console
echo "Almost ready..." > /dev/console
echo "Ready!" > /dev/console
exit 0

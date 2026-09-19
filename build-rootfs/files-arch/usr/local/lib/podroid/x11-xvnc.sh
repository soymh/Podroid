#!/bin/sh
# x11-xvnc.sh — ArchDroid Xvnc launcher (run directly by podroid-xvnc.service).
# Faithful port of the Xvnc half of the podroid-x11 OpenRC service: DPI from
# the kernel cmdline, stale-lock cleanup, foreground exec (systemd supervises
# the process itself — no pidfile dance needed).

XVNC_DISPLAY=:0
XVNC_GEOMETRY=1280x720
XVNC_PORT=5900

# Per-boot DPI from the kernel cmdline token written by the Android app.
# Digit-only capture: /proc/cmdline ends in '\n', which would otherwise ride
# along into the value and make Xvnc reject -dpi.
XVNC_DPI=$(sed -n 's/.*podroid\.x11\.dpi=\([0-9]*\).*/\1/p' /proc/cmdline 2>/dev/null)
[ -z "$XVNC_DPI" ] && XVNC_DPI=96

# /tmp lives on the persistent ext4 overlay, so a stale X server lock from a
# previous boot blocks Xvnc with "Server is already active for display 0".
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0

# Xvnc: combined X server + RFB. No auth, listens on 5900.
# -SecurityTypes None is fine because the socket only sees SLIRP loopback;
# the host (phone) reaches it via 127.0.0.1.
exec /usr/bin/Xvnc $XVNC_DISPLAY \
    -geometry $XVNC_GEOMETRY \
    -depth 24 \
    -SecurityTypes None \
    -localhost no \
    -rfbport $XVNC_PORT \
    -AlwaysShared \
    -dpi $XVNC_DPI \
    -AcceptSetDesktopSize

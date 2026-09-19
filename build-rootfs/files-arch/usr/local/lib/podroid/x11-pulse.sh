#!/bin/sh
# x11-pulse.sh — ArchDroid PulseAudio launcher (run by podroid-pulse.service).
# Faithful port of the PulseAudio half of podroid-x11: system-wide-style
# daemon writing raw S16LE PCM to TCP 4713 for the in-app audio viewer.
# --daemonize=no with explicit XDG_RUNTIME_DIR so it runs as root without
# tripping pulse's "system mode is risky" refusal.

PA_PORT=4713
PA_RUNTIME=/run/podroid-pulse

mkdir -p "$PA_RUNTIME"
chmod 755 "$PA_RUNTIME"

PULSE_RUNTIME_PATH="$PA_RUNTIME" \
XDG_RUNTIME_DIR="$PA_RUNTIME" \
exec /usr/bin/pulseaudio \
    --daemonize=no \
    --disallow-exit \
    --exit-idle-time=-1 \
    --load="module-null-sink sink_name=podroid_sink rate=44100 channels=2 format=s16le" \
    --load="module-simple-protocol-tcp source=podroid_sink.monitor record=true rate=44100 format=s16le channels=2 listen=0.0.0.0 port=$PA_PORT" \
    --load="module-native-protocol-unix"

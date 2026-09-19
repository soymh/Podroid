#!/bin/sh
# podroid-migrate.sh — ArchDroid system migrations (systemd oneshot, first).
# Faithful port of the podroid-migrate OpenRC service start() body: runs
# /etc/podroid/migrations/<v>.sh for applied < v <= system-version, then
# advances the applied-version marker atomically. Scripts MUST stay
# idempotent (a crash re-runs them next boot).

SYSVER_FILE="/etc/podroid/system-version"
APPLIED_FILE="/mnt/persist/.podroid/applied-version"
MIGRATIONS_DIR="/etc/podroid/migrations"

mkdir -p /mnt/persist/.podroid

current=$(cat "$SYSVER_FILE" 2>/dev/null || echo 0)
applied=$(cat "$APPLIED_FILE" 2>/dev/null || echo "")

# Fresh install (no marker): seed the marker, run nothing — the image
# already ships the current state.
if [ -z "$applied" ]; then
    printf '%s\n' "$current" > "$APPLIED_FILE.tmp" && mv "$APPLIED_FILE.tmp" "$APPLIED_FILE"
    exit 0
fi

# Fast path / downgrade: nothing to do.
if [ "$current" -le "$applied" ] 2>/dev/null; then
    exit 0
fi

# Run each migrations/<v>.sh with applied < v <= current, in ascending
# numeric order. Stop at the first failure so it (and later scripts) retry
# next boot instead of being marked applied.
last_ok="$applied"
failed=0
for base in $(ls "$MIGRATIONS_DIR" 2>/dev/null | sed -n 's/\.sh$//p' | sort -n); do
    case "$base" in *[!0-9]*) continue ;; esac   # digits only
    if [ "$base" -gt "$applied" ] 2>/dev/null && [ "$base" -le "$current" ] 2>/dev/null; then
        echo "podroid-migrate: applying $base" > /dev/console
        if sh "$MIGRATIONS_DIR/$base.sh" > /dev/console 2>&1; then
            last_ok="$base"
        else
            echo "podroid-migrate: $base failed, stopping (will retry next boot)" > /dev/console
            failed=1
            break
        fi
    fi
done

# Advance the marker atomically: to current if nothing failed, otherwise to
# the last success (unchanged if none), never past a failure.
if [ "$failed" -eq 0 ]; then
    marker="$current"
else
    marker="$last_ok"
fi
printf '%s\n' "$marker" > "$APPLIED_FILE.tmp" && mv "$APPLIED_FILE.tmp" "$APPLIED_FILE"
exit 0

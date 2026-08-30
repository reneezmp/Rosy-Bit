#!/usr/bin/env bash
#
# Build, replace and relaunch, in an order that does not race.
#
#   ./scripts/install.sh              # build first
#   ./scripts/install.sh --no-build   # install what is already in dist/
#
# Quitting is asynchronous. `osascript -e 'quit app "RosyBit"'` returns once the
# event is delivered, not once the app is gone — and Rosy Bit's own shutdown
# waits up to two seconds for llama-server to exit. Deleting the bundle in that
# window leaves LaunchServices pointing at a bundle that no longer exists, and
# the next `open` fails with `-609`. So: wait for the process to actually go.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="RosyBit"
INSTALLED="/Applications/${APP_NAME}.app"
BUILT="$ROOT/dist/${APP_NAME}.app"

if [ "${1:-}" != "--no-build" ]; then
    make -C "$ROOT" app
fi

if [ ! -d "$BUILT" ]; then
    printf 'error: %s does not exist — run make app first\n' "$BUILT" >&2
    exit 1
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    printf 'quitting %s' "$APP_NAME"
    osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true

    for _ in $(seq 1 50); do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then break; fi
        printf '.'
        sleep 0.2
    done

    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        printf '\n  did not quit in 10s, killing it\n'
        pkill -x "$APP_NAME" || true
        sleep 1
    else
        printf ' gone\n'
    fi
fi

# An orphaned llama-server would hold the port against the new build. Rosy Bit
# clears one on launch, but not if it is on a port this build no longer uses.
if pgrep -x llama-server >/dev/null 2>&1; then
    printf 'stopping a leftover llama-server\n'
    pkill -x llama-server || true
fi

rm -rf "$INSTALLED"
cp -R "$BUILT" "$INSTALLED"
xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true

open "$INSTALLED"
printf 'installed and launched %s\n' "$INSTALLED"

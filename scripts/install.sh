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

# An orphaned child may still be on a port this build no longer uses. Only touch
# the PID Rosy Bit recorded and verify its executable name first; other
# llama-server instances on this account belong to their own applications.
PID_FILE="$HOME/Library/Application Support/RosyBit/.llama-server.pid"
if [ -f "$PID_FILE" ]; then
    orphan_pid="$(tr -d '[:space:]' < "$PID_FILE")"
    case "$orphan_pid" in
        ''|*[!0-9]*) orphan_pid='' ;;
    esac

    if [ -n "$orphan_pid" ] && kill -0 "$orphan_pid" 2>/dev/null; then
        orphan_name="$(ps -p "$orphan_pid" -o comm= 2>/dev/null || true)"
        if [ "$(basename "$orphan_name")" = "llama-server" ]; then
            printf 'stopping Rosy Bit llama-server (pid %s)\n' "$orphan_pid"
            kill "$orphan_pid" 2>/dev/null || true
            for _ in $(seq 1 20); do
                if ! kill -0 "$orphan_pid" 2>/dev/null; then break; fi
                sleep 0.1
            done
        fi
    fi
    # Keep a still-live PID recorded so the newly installed app can perform its
    # own verified cleanup. A dead or stale PID file has no further value.
    if [ -z "$orphan_pid" ] || ! kill -0 "$orphan_pid" 2>/dev/null; then
        rm -f "$PID_FILE"
    fi
fi

rm -rf "$INSTALLED"
cp -R "$BUILT" "$INSTALLED"
xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true

open "$INSTALLED"
printf 'installed and launched %s\n' "$INSTALLED"

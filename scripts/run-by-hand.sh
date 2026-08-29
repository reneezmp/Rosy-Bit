#!/usr/bin/env bash
#
# Step 1 of the build order: run llama-server by hand, exactly the way the app
# will run it. Nothing else in this project matters until this works.
#
#   ./scripts/run-by-hand.sh
#   THREADS=1 ./scripts/run-by-hand.sh      # if the UI stutters mid-generation
#
# Leave it running in the foreground and use scripts/smoke-test.sh from a second
# terminal. Ctrl-C to stop.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
SERVER="${SERVER:-$ROOT/vendor/$ARCH/llama-server}"

MODEL_DIR="${MODEL_DIR:-$HOME/Library/Application Support/RosyBit}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-1337}"
CTX="${CTX:-2048}"
THREADS="${THREADS:-2}"

if [ ! -x "$SERVER" ]; then
    printf 'error: no llama-server at %s\n' "$SERVER" >&2
    printf '       run ./scripts/fetch-llama-server.sh %s first\n' "$ARCH" >&2
    exit 1
fi

MODEL="${MODEL:-}"
if [ -z "$MODEL" ]; then
    MODEL="$(find "$MODEL_DIR" -maxdepth 1 -name '*.gguf' 2>/dev/null | sort | head -n1)"
fi
if [ -z "$MODEL" ] || [ ! -f "$MODEL" ]; then
    printf 'error: no .gguf in %s\n' "$MODEL_DIR" >&2
    printf '       run ./scripts/fetch-model.sh first\n' >&2
    exit 1
fi

printf 'server : %s\n' "$SERVER"
printf 'model  : %s\n' "$MODEL"
printf 'listen : http://%s:%s/v1\n\n' "$HOST" "$PORT"

# 127.0.0.1 only, never 0.0.0.0 — this machine goes to the courthouse.
# No -ngl: the Bonsai examples assume CUDA or Apple Silicon Metal, and the
# HD 615 is neither. CPU only until proven otherwise.
exec "$SERVER" \
    --host "$HOST" \
    --port "$PORT" \
    -m "$MODEL" \
    -c "$CTX" \
    -t "$THREADS" \
    --jinja \
    --alias "$(basename "${MODEL%.gguf}")"

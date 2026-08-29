#!/usr/bin/env bash
#
# Download the Bonsai 1.7B Q1_0 GGUF into the model directory.
#
#   ./scripts/fetch-model.sh
#   MODEL_FILE=Bonsai-1.7B-Q1_0.gguf ./scripts/fetch-model.sh
#
# Gotcha #3: the model deliberately lives outside the .app bundle, so models can
# be swapped without rebuilding. Anything with a .gguf extension dropped into
# this folder shows up in the app's Model submenu.

set -euo pipefail

MODEL_REPO="${MODEL_REPO:-prism-ml/Bonsai-1.7B-gguf}"
MODEL_DIR="${MODEL_DIR:-$HOME/Library/Application Support/RosyBit}"
QUANT="${QUANT:-Q1_0}"

mkdir -p "$MODEL_DIR"

resolve_filename() {
    # Ask the Hub which files exist rather than guessing at the exact casing.
    local api="https://huggingface.co/api/models/${MODEL_REPO}"
    local json
    json="$(curl -fsSL --retry 3 --retry-delay 2 "$api")" || return 1

    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | QUANT="$QUANT" python3 -c '
import json, os, sys
quant = os.environ["QUANT"].lower()
names = [s.get("rfilename", "") for s in json.load(sys.stdin).get("siblings", [])]
ggufs = [n for n in names if n.lower().endswith(".gguf")]
match = [n for n in ggufs if quant in n.lower()]
print((match or ggufs or [""])[0])
'
    else
        printf '%s' "$json" \
            | tr ',' '\n' \
            | grep -o '"rfilename":"[^"]*\.gguf"' \
            | sed 's/.*":"//; s/"$//' \
            | grep -i "$QUANT" \
            | head -n1
    fi
}

MODEL_FILE="${MODEL_FILE:-$(resolve_filename)}"

if [ -z "$MODEL_FILE" ]; then
    printf 'error: could not find a %s .gguf in %s\n' "$QUANT" "$MODEL_REPO" >&2
    printf '       browse https://huggingface.co/%s and set MODEL_FILE=...\n' "$MODEL_REPO" >&2
    exit 1
fi

DEST="$MODEL_DIR/$(basename "$MODEL_FILE")"

if [ -s "$DEST" ]; then
    printf 'already present: %s (%s)\n' "$DEST" "$(du -h "$DEST" | cut -f1)"
    exit 0
fi

URL="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}?download=true"
printf 'downloading %s\n' "$MODEL_FILE"
# -C - resumes a partial download; the file is small but the courthouse wifi
# is not always kind.
curl -fL --retry 3 --retry-delay 2 -C - -o "$DEST" "$URL"

printf 'installed %s (%s)\n' "$DEST" "$(du -h "$DEST" | cut -f1)"

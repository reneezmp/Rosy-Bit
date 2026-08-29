#!/usr/bin/env bash
#
# Prove the endpoint works. If this returns something coherent, everything
# downstream is just configuration.
#
#   ./scripts/smoke-test.sh
#   PORT=1337 ./scripts/smoke-test.sh

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-1337}"
BASE="http://${HOST}:${PORT}"
PROMPT="${PROMPT:-Write a 4-word title for a note about sleep settings on old laptops.}"
WAIT_SECONDS="${WAIT_SECONDS:-120}"

printf 'waiting for %s/health ' "$BASE"
deadline=$(( $(date +%s) + WAIT_SECONDS ))
until curl -fsS "${BASE}/health" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        printf '\nerror: no healthy server after %ss\n' "$WAIT_SECONDS" >&2
        printf '       is it still loading the model? check the log:\n' >&2
        printf '       tail -f ~/Library/Logs/RosyBit/llama-server.log\n' >&2
        exit 1
    fi
    printf '.'
    sleep 1
done
printf ' ok\n\n'

payload() {
    printf '{"model":"bonsai","messages":[{"role":"user","content":%s}]}' \
        "$(printf '%s' "$PROMPT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
}

printf 'prompt : %s\n' "$PROMPT"
response="$(curl -fsS "${BASE}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$(payload)")"

if command -v python3 >/dev/null 2>&1; then
    printf 'reply  : '
    printf '%s' "$response" | python3 -c '
import json, sys
try:
    body = json.load(sys.stdin)
    print(body["choices"][0]["message"]["content"].strip())
except Exception:
    print("could not parse response:", file=sys.stderr)
    raise SystemExit(1)
'
else
    printf 'reply  : %s\n' "$response"
fi

printf '\nendpoint ready: %s/v1\n' "$BASE"

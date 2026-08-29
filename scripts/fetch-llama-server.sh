#!/usr/bin/env bash
#
# Fetch prebuilt llama-server binaries into vendor/<arch>/ so `make app` can
# stage them inside the bundle.
#
#   ./scripts/fetch-llama-server.sh              # both slices (build machine)
#   ./scripts/fetch-llama-server.sh x86_64       # just Rosy's slice
#   LLAMA_TAG=b10700 ./scripts/fetch-llama-server.sh
#
# The tag must be at or after the two upstream PRs that matter here:
#   #21273  ggml: add Q1_0 1-bit quantization support (CPU)
#   #21636  ggml-cpu: optimized x86 and generic cpu q1_0 dot
# Q1_0 is upstream, so the PrismML fork is NOT needed. That fork is only
# required for ternary Q2_0.
#
# This also checks LC_BUILD_VERSION on the downloaded binary. A binary built
# against a newer SDK simply refuses to launch on Ventura, and that failure is
# confusing if you meet it later, wrapped in a Swift app.

set -euo pipefail

LLAMA_TAG="${LLAMA_TAG:-b10684}"
LLAMA_REPO="${LLAMA_REPO:-ggml-org/llama.cpp}"
DEPLOYMENT_TARGET="13.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor"

if [ "$#" -gt 0 ]; then
    ARCHES=("$@")
else
    ARCHES=(x86_64 arm64)
fi

asset_slug() {
    case "$1" in
        x86_64) printf 'x64' ;;
        arm64)  printf 'arm64' ;;
        *) printf 'unsupported arch: %s\n' "$1" >&2; return 1 ;;
    esac
}

fetch_arch() {
    local arch="$1"
    local slug base url tmp extracted dest
    slug="$(asset_slug "$arch")"
    base="https://github.com/${LLAMA_REPO}/releases/download/${LLAMA_TAG}"

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    # Recent releases ship .tar.gz; older ones shipped .zip.
    local archive=""
    for extension in tar.gz zip; do
        url="${base}/llama-${LLAMA_TAG}-bin-macos-${slug}.${extension}"
        printf 'trying %s\n' "$url"
        if curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/asset.${extension}" "$url"; then
            archive="$tmp/asset.${extension}"
            break
        fi
    done

    if [ -z "$archive" ]; then
        printf 'error: no macOS %s asset for tag %s\n' "$slug" "$LLAMA_TAG" >&2
        printf '       check https://github.com/%s/releases\n' "$LLAMA_REPO" >&2
        return 1
    fi

    case "$archive" in
        *.tar.gz) tar -xzf "$archive" -C "$tmp" ;;
        *.zip)    unzip -qq "$archive" -d "$tmp" ;;
    esac

    extracted="$(find "$tmp" -type f -name llama-server -perm -u+x -print -quit)"
    if [ -z "$extracted" ]; then
        printf 'error: llama-server not found inside the archive\n' >&2
        return 1
    fi

    # Keep llama-server next to the dylibs it was built against so @rpath
    # resolution keeps working. We skip llama-cli and friends: unused weight.
    dest="$VENDOR/$arch"
    rm -rf "$dest"
    mkdir -p "$dest"
    cp "$extracted" "$dest/"
    find "$(dirname "$extracted")" -maxdepth 1 -name '*.dylib' -exec cp {} "$dest/" \;
    chmod +x "$dest/llama-server"

    printf 'installed vendor/%s/ (%s)\n' "$arch" "$(du -sh "$dest" | cut -f1)"
    check_minos "$dest/llama-server"
}

check_minos() {
    local binary="$1" minos oldest
    command -v otool >/dev/null 2>&1 || return 0

    minos="$(otool -l "$binary" 2>/dev/null \
        | awk '/LC_BUILD_VERSION/ { found = 1 } found && /minos/ { print $2; exit }')"
    if [ -z "$minos" ]; then
        printf '  minos: not reported (older load command) — verify on Rosy\n'
        return 0
    fi

    oldest="$(printf '%s\n%s\n' "$minos" "$DEPLOYMENT_TARGET" | sort -V | head -n1)"
    if [ "$oldest" = "$DEPLOYMENT_TARGET" ] && [ "$minos" != "$DEPLOYMENT_TARGET" ]; then
        printf '  minos: %s — TOO NEW. This will not launch on Ventura %s.\n' \
            "$minos" "$DEPLOYMENT_TARGET" >&2
        printf '  Compile llama.cpp from source on Rosy instead; see docs/RUNBOOK.md.\n' >&2
    else
        printf '  minos: %s — OK for macOS %s\n' "$minos" "$DEPLOYMENT_TARGET"
    fi
}

printf 'llama.cpp %s\n' "$LLAMA_TAG"
for arch in "${ARCHES[@]}"; do
    fetch_arch "$arch"
done

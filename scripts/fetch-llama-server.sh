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

# What the binary must be able to launch on — which is the OS of the machine
# that will actually serve, NOT the app's deployment target. Rosy runs Ventura
# 13.7.8, so a binary needing 13.3 is fine there even though the app bundle
# itself targets 13.0.
#
# Defaults to this machine's version, which is the right answer when running
# step 1 on Rosy as the runbook says. When fetching Rosy's slice from the M4,
# pass Rosy's version explicitly:
#
#   TARGET_MACOS=13.7.8 ./scripts/fetch-llama-server.sh x86_64
#
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
HOST_MACOS="$(sw_vers -productVersion 2>/dev/null || true)"
if [ -n "${TARGET_MACOS:-}" ]; then
    TARGET_EXPLICIT=1
else
    TARGET_EXPLICIT=0
    TARGET_MACOS="${HOST_MACOS:-13.0}"
fi

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
    check_minos "$dest/llama-server" "$arch"
}

check_minos() {
    local binary="$1" arch="$2" minos oldest
    command -v otool >/dev/null 2>&1 || return 0

    minos="$(otool -l "$binary" 2>/dev/null \
        | awk '/LC_BUILD_VERSION/ { found = 1 } found && /minos/ { print $2; exit }')"
    if [ -z "$minos" ]; then
        printf '  minos: not reported (older load command) — verify on Rosy\n'
        return 0
    fi

    # OK when minos <= TARGET_MACOS, equality included.
    oldest="$(printf '%s\n%s\n' "$minos" "$TARGET_MACOS" | sort -V | head -n1)"
    if [ "$oldest" = "$minos" ]; then
        printf '  minos: %s — OK for macOS %s\n' "$minos" "$TARGET_MACOS"
        if [ "$arch" != "$HOST_ARCH" ] && [ "$TARGET_EXPLICIT" = "0" ]; then
            printf '  note:  checked against THIS machine. For Rosy, re-run with\n'
            printf '         TARGET_MACOS=$(ssh rosy sw_vers -productVersion)\n'
        fi
        return 0
    fi

    printf '  minos: %s — TOO NEW. This will not launch on macOS %s.\n' \
        "$minos" "$TARGET_MACOS" >&2

    # arm64 only ever runs on the build machine, so a newer minos there is not
    # fatal. x86_64 is Rosy's slice: bundling it would produce an app that dies
    # on launch in a way that looks like a Gatekeeper problem, so refuse now
    # and take the payload away rather than leave it to be picked up by
    # `make app`.
    if [ "$arch" != "x86_64" ] || [ "${ALLOW_NEW_MINOS:-0}" = "1" ]; then
        printf '  (continuing anyway)\n' >&2
        return 0
    fi

    rm -rf "$(dirname "$binary")"
    printf '\n  If %s is not the version that will run this, re-run with the\n' "$TARGET_MACOS" >&2
    printf '  right one, e.g. TARGET_MACOS=13.7.8 %s %s\n\n' "$0" "$arch" >&2
    printf '  Otherwise compile llama.cpp from source on Rosy — you do NOT need\n' >&2
    printf '  the prism fork, Q1_0 is upstream. See docs/RUNBOOK.md step 1a.\n' >&2
    printf '  To bundle it regardless: ALLOW_NEW_MINOS=1 %s %s\n' "$0" "$arch" >&2
    return 1
}

printf 'llama.cpp %s — checking binaries against macOS %s\n' "$LLAMA_TAG" "$TARGET_MACOS"
for arch in "${ARCHES[@]}"; do
    fetch_arch "$arch"
done

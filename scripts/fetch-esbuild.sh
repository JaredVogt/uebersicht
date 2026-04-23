#!/usr/bin/env bash
#
# Downloads a universal `esbuild` binary into
# `Uebersicht/Server/Resources/bin/esbuild` so the app can ship it in the
# `.app` bundle.
#
# esbuild distributes per-arch tarballs on npm; we pull both darwin-arm64 and
# darwin-x64 and stitch them into a fat binary with `lipo`. The binary is
# cached by version, so subsequent builds are instant.
#
# Run from the repo root (or any subdirectory — the script resolves paths).
set -euo pipefail

ESBUILD_VERSION="${ESBUILD_VERSION:-0.24.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST_DIR="$REPO_ROOT/Uebersicht/Server/Resources/bin"
DEST="$DEST_DIR/esbuild"
STAMP="$DEST_DIR/.esbuild-version"

mkdir -p "$DEST_DIR"

if [ -x "$DEST" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$ESBUILD_VERSION" ]; then
    echo "esbuild $ESBUILD_VERSION already present at $DEST"
    exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fetch_arch() {
    local pkg="$1" out="$2"
    local url="https://registry.npmjs.org/${pkg}/-/${pkg##*/}-${ESBUILD_VERSION}.tgz"
    echo "fetching $url"
    curl -sSLf "$url" -o "$TMP_DIR/${out}.tgz"
    mkdir -p "$TMP_DIR/$out"
    tar -xzf "$TMP_DIR/${out}.tgz" -C "$TMP_DIR/$out"
    mv "$TMP_DIR/$out/package/bin/esbuild" "$TMP_DIR/$out.bin"
}

fetch_arch "@esbuild/darwin-arm64" arm64
fetch_arch "@esbuild/darwin-x64" x64

lipo -create "$TMP_DIR/arm64.bin" "$TMP_DIR/x64.bin" -output "$DEST"
chmod +x "$DEST"
echo "$ESBUILD_VERSION" > "$STAMP"

echo "wrote universal esbuild $ESBUILD_VERSION to $DEST"

#!/usr/bin/env bash
#
# Builds the browser-side client bundle out of `Uebersicht/Client/` and
# writes the ES modules into `Uebersicht/Server/Resources/public/` where the
# app's in-process server (WidgetCoordinator) picks them up.
#
# Outputs:
#   public/client.js      — entry bundle (loaded from index.html)
#   public/uebersicht.js  — `uebersicht` module (widgets import it)
#
# Dependencies (preact, @emotion/css, @emotion/styled) are fetched straight
# from the npm registry into `Uebersicht/Client/node_modules/` the same way
# `scripts/fetch-esbuild.sh` pulls the esbuild binary — so the project
# builds without `npm` in PATH. Versions are pinned below and mirrored in
# `Uebersicht/Client/package.json` so IDEs pick up completions.
#
# If `node_modules/` already has the right versions the fetch step is a
# no-op, so incremental builds stay fast.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$REPO_ROOT/Uebersicht/Client"
DEST_DIR="$REPO_ROOT/Uebersicht/Server/Resources/public"
NODE_MODULES="$CLIENT_DIR/node_modules"
ESBUILD="$REPO_ROOT/Uebersicht/Server/Resources/bin/esbuild"

# Pinned deps. Keep these aligned with Uebersicht/Client/package.json.
# `@emotion/styled` intentionally absent: it pulls React + @emotion/react +
# @babel/runtime, all of which we'd have to mirror. We ship a ~15-line
# `styled` shim in uebersicht.js that covers the 90% case on top of
# `@emotion/css` (the framework-agnostic emotion variant).
declare -a DEPS=(
    "preact@10.24.3"
    "@emotion/css@11.13.4"
    "@emotion/cache@11.13.1"
    "@emotion/utils@1.4.1"
    "@emotion/hash@0.9.2"
    "@emotion/memoize@0.9.0"
    "@emotion/sheet@1.4.0"
    "@emotion/weak-memoize@0.4.0"
    "@emotion/serialize@1.3.2"
    "@emotion/unitless@0.10.0"
    "stylis@4.2.0"
    "csstype@3.1.3"
)

if [ ! -x "$ESBUILD" ]; then
    echo "esbuild not found at $ESBUILD — run scripts/fetch-esbuild.sh first" >&2
    exit 1
fi

fetch_pkg() {
    local spec="$1"
    local pkg="${spec%@*}"
    local version="${spec##*@}"
    local dest="$NODE_MODULES/$pkg"
    local stamp="$dest/.version"

    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$version" ]; then
        return 0
    fi

    local name_only="${pkg##*/}"
    local url="https://registry.npmjs.org/${pkg}/-/${name_only}-${version}.tgz"
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN

    echo "fetching $spec"
    curl -sSLf "$url" -o "$tmpdir/pkg.tgz"
    mkdir -p "$dest"
    # `package/` is the conventional top-level folder inside an npm tarball.
    tar -xzf "$tmpdir/pkg.tgz" -C "$tmpdir"
    rm -rf "$dest"
    mv "$tmpdir/package" "$dest"
    echo "$version" > "$stamp"
}

mkdir -p "$NODE_MODULES" "$DEST_DIR"
for spec in "${DEPS[@]}"; do
    fetch_pkg "$spec"
done

echo "bundling client.js"
"$ESBUILD" "$CLIENT_DIR/client.js" \
    --bundle \
    --format=esm \
    --target=safari16 \
    --minify \
    --sourcemap \
    --outfile="$DEST_DIR/client.js"

echo "bundling uebersicht.js"
"$ESBUILD" "$CLIENT_DIR/uebersicht.js" \
    --bundle \
    --format=esm \
    --target=safari16 \
    --minify \
    --sourcemap \
    --outfile="$DEST_DIR/uebersicht.js"

echo "copying index.html + main.css"
cp "$CLIENT_DIR/index.html" "$DEST_DIR/index.html"
# Preserve main.css from the old public/ dir; it's hand-maintained.
# If it's missing, write the minimal default.
if [ ! -f "$DEST_DIR/main.css" ]; then
    cat > "$DEST_DIR/main.css" <<'CSS'
body,
html {
  background: transparent;
  padding: 0;
  margin: 0;
  height: 100%;
  width: 100%;
  overflow: hidden;
}
#uebersicht {
  position: absolute;
  height: 100%;
  width: 100%;
  padding: 0;
  margin: 0;
  overflow: hidden;
}
.widget {
  position: absolute;
}
CSS
fi

echo "client build done — wrote $DEST_DIR"

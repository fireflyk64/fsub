#!/usr/bin/env bash
# Build the browser player's emulator: binjgb (https://github.com/binji/binjgb)
# at a pinned commit, with the patches in this folder applied by `git am`
# (the link-cable hooks web/link.js needs), compiled to wasm with Emscripten,
# and copied to web/binjgb.js and web/binjgb.wasm.
#
# usage: tools/binjgb/build.sh [work-dir]
#   work-dir (default ../binjgb next to this repo, or $BINJGB_DIR) holds the
#   binjgb checkout.  A checkout that is already there is reset to the pinned
#   commit on a branch of its own (fsub-link) and patched again; other
#   branches are left alone.
# needs: git, cmake, make, Emscripten (emcc on PATH, or ~/emsdk/emsdk_env.sh).
#
# To change the emulator: commit on top of the pinned commit in the work
# dir, then `git format-patch -o tools/binjgb <pinned>..HEAD` (replacing the
# old patches) and run this again.
set -euo pipefail

PIN=6c04827f63d272f32afd86138a8e7262b3800344   # binjgb master, 2025: "Added an emulator_set_registers function"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${1:-${BINJGB_DIR:-$REPO/../binjgb}}"

if ! command -v emcc >/dev/null; then
  [[ -f "$HOME/emsdk/emsdk_env.sh" ]] && source "$HOME/emsdk/emsdk_env.sh" >/dev/null 2>&1
  command -v emcc >/dev/null || { echo "emcc not found: install Emscripten (emsdk) or put it on PATH" >&2; exit 1; }
fi

[[ -d "$WORK/.git" ]] || git clone -q https://github.com/binji/binjgb "$WORK"
cd "$WORK"
git cat-file -e "$PIN^{commit}" 2>/dev/null || git fetch -q origin
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "$WORK has uncommitted changes; commit or stash them first" >&2; exit 1; }
git checkout -q -B fsub-link "$PIN"
git -c user.name="fsub build" -c user.email="fsub-build@localhost" am -q --committer-date-is-author-date "$HERE"/*.patch

mkdir -p out/fsub
cd out/fsub
emcmake cmake ../.. -DCMAKE_BUILD_TYPE=Release -DWERROR=ON -DWASM=true >/dev/null 2>&1
make --no-print-directory 2>&1 | grep -v '^\[' || true
[[ -s binjgb.wasm && -s binjgb.js ]] || { echo "the build produced no binjgb.wasm" >&2; exit 1; }
cp binjgb.js binjgb.wasm "$REPO/web/"
echo "web/binjgb.js, web/binjgb.wasm <- binjgb $(git -C "$WORK" rev-parse --short "$PIN") + $(ls "$HERE"/*.patch | wc -l) patch(es), $(emcc --version | head -1 | sed 's/ (.*//')"

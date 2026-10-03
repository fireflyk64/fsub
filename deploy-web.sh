#!/usr/bin/env bash
# Build the ROM and publish it plus the browser player to <pages-repo>/geometrydash/.
# Only that subfolder is ever touched; other folders in the Pages repo are left alone.
#
# usage: ./deploy-web.sh [--no-push] [pages-repo-dir]
#   pages-repo-dir defaults to ../fireflyk64.github.io (or $PAGES_DIR)
# needs: rgbds (rgbasm/rgblink/rgbfix) on PATH, make, git with push access.
set -euo pipefail

PUSH=1
if [[ "${1:-}" == "--no-push" ]]; then PUSH=0; shift; fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAGES="$(cd "${1:-${PAGES_DIR:-$HERE/../fireflyk64.github.io}}" && pwd)"
DEST="$PAGES/geometrydash"

[[ -d "$PAGES/.git" ]] || { echo "not a git checkout: $PAGES" >&2; exit 1; }
command -v rgbasm >/dev/null || { echo "rgbasm not found: install rgbds (e.g. sudo apt install rgbds)" >&2; exit 1; }

echo "== build ROM"
make -C "$HERE" -B main.gb >/dev/null
[[ -s "$HERE/main.gb" ]] || { echo "build produced no ROM" >&2; exit 1; }

echo "== update $DEST"
git -C "$PAGES" pull --rebase -q
mkdir -p "$DEST"
cp "$HERE"/web/* "$DEST"/
cp "$HERE/main.gb" "$DEST/geometrydash.gb"

cd "$PAGES"
git add geometrydash
if git diff --cached --quiet; then echo "nothing changed; site already up to date"; exit 0; fi
git commit -q -m "Update geometrydash ($(git -C "$HERE" rev-parse --short HEAD))"
git --no-pager show --stat --format=%s HEAD | tail -8
if (( PUSH )); then git push; echo "pushed -> https://$(basename "$PAGES")/geometrydash/"; else echo "committed, not pushed (--no-push)"; fi

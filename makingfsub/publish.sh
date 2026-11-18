#!/usr/bin/env bash
# Publish this write-up to <pages-repo>/makingfsub/, with every HTML comment stripped out
# (the EDIT: notes, and any drafts or notes left in comments).
# Only that subfolder is ever touched; other folders in the Pages repo are left alone.
#
# usage: ./publish.sh [--no-push] [pages-repo-dir]
#   pages-repo-dir defaults to ../../fireflyk64.github.io (or $PAGES_DIR)
# needs: perl, git with push access.
set -euo pipefail

PUSH=1
if [[ "${1:-}" == "--no-push" ]]; then PUSH=0; shift; fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAGES="$(cd "${1:-${PAGES_DIR:-$HERE/../../fireflyk64.github.io}}" && pwd)"
DEST="$PAGES/makingfsub"

[[ -d "$PAGES/.git" ]] || { echo "not a git checkout: $PAGES" >&2; exit 1; }

echo "== update $DEST"
git -C "$PAGES" pull --rebase -q
rm -rf "$DEST"
mkdir -p "$DEST/img"
cp "$HERE"/img/* "$DEST/img/"
# a comment alone on its line takes the line with it; one inside running text leaves the text as it was
perl -0pe 's/^[ \t]*<!--(?:(?!-->).)*-->[ \t]*\n//gms; s/<!--(?:(?!-->).)*-->//gs' "$HERE/index.html" > "$DEST/index.html"
if grep -q -e '<!--' -e '-->' -e 'EDIT:' "$DEST/index.html"; then echo "a comment survived the strip; not publishing" >&2; exit 1; fi

cd "$PAGES"
git add -A makingfsub
if git diff --cached --quiet; then echo "nothing changed; site already up to date"; exit 0; fi
git commit -q -m "Update makingfsub ($(git -C "$HERE" rev-parse --short HEAD))"
git --no-pager show --stat --format=%s HEAD | tail -8
if (( PUSH )); then git push; echo "pushed -> https://$(basename "$PAGES")/makingfsub/"; else echo "committed, not pushed (--no-push)"; fi

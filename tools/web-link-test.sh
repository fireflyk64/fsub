#!/usr/bin/env bash
# Two browser pages of the player (web/) race each other through the lobby:
# starts a local lobbylink server and a web server, then runs
# tools/web-link-test.mjs in headless Chrome.
#
# usage: tools/web-link-test.sh            (prints ok/FAIL lines; screenshots in $OUT)
#        LOBBY_URL=https://pqrstuvw.xyz/lobbylink PORT=5173 tools/web-link-test.sh
#          runs the pages against the public server instead (it lets pages from
#          localhost:5173 in), relay and all; no local lobby server then.
# needs: a p2p-lobby-server binary ($LOBBY_BIN, default ../lobbylink/p2p-lobby-server),
#        python3, node, playwright ($PLAYWRIGHT_DIR: a folder whose node_modules has it),
#        google-chrome ($CHROME), and fzero.gb built.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LOBBY_BIN="${LOBBY_BIN:-$REPO/../lobbylink/p2p-lobby-server}"
PW="${PLAYWRIGHT_DIR:-$REPO/../dosbox3d/build-web/playwright}"
PORT="${PORT:-8000}" LOBBY_PORT="${LOBBY_PORT:-8787}"
OUT="${OUT:-$(mktemp -d)}"
SITE="$OUT/site"

mkdir -p "$SITE"
cp "$REPO"/web/* "$SITE"/
cp "$REPO/fzero.gb" "$SITE/fsub.gb"
cp "$REPO/fzero.sym" "$SITE/fsub.sym"

LOBBY_PID=""
if [[ -z "${LOBBY_URL:-}" ]]; then
  LOBBY_URL="http://127.0.0.1:$LOBBY_PORT"
  "$LOBBY_BIN" --listen-http "127.0.0.1:$LOBBY_PORT" --public-url "$LOBBY_URL" \
    --allowed-origin "http://localhost:$PORT" --log-level warn >"$OUT/lobby.log" 2>&1 &
  LOBBY_PID=$!
fi
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SITE" >"$OUT/http.log" 2>&1 &
HTTP_PID=$!
trap 'kill $LOBBY_PID $HTTP_PID 2>/dev/null || true' EXIT
for _ in $(seq 50); do curl -sf "$LOBBY_URL/healthz" >/dev/null && curl -sf "http://127.0.0.1:$PORT/" >/dev/null && break; sleep 0.2; done

PLAYWRIGHT_DIR="$PW" SHOT_DIR="$OUT" node "$HERE/web-link-test.mjs" "http://localhost:$PORT/" "$LOBBY_URL" "$REPO/fzero.sym"
echo "logs and screenshots: $OUT"

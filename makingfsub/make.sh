#!/usr/bin/env bash
# Capture frames from the built ROM and draw the blog figures into img/.
# The figures in img/ came from commit 9ca59dc, except corner-kink.png (f01cb09); the frame
# picks in figs.py are for those builds, so a newer ROM may need new picks.
# needs: fzero.gb and fzero.sym (make), node, python3 with Pillow and numpy.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -s ../fzero.gb && -s ../fzero.sym ]] || { echo "build the ROM first: make -C .." >&2; exit 1; }
rm -rf cap
node shots.js cap/t0 --track 0 --bot expert --frames 5200 --every 20
for t in 1 2 3; do node shots.js cap/t$t --track $t --bot expert --frames 2400 --every 40; done
node shots.js cap/prac --track 0 --mode practice --bot none --script practice --frames 9000 --every 100000
node shots.js cap/mash --track 0 --bot masher --frames 9000 --every 10 --wreck
node shots.js cap/dense1 --track 0 --bot expert --frames 262 --every 100000 --dense 182,262
node shots.js cap/dense3 --track 0 --bot expert --frames 1760 --every 100000 --dense 1480,1760
node shots.js cap/kink --track 0 --bot expert --frames 600 --every 4
python3 figs.py

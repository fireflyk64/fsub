# fsub: F-Zero style racer for Game Boy.  Needs rgbds and python3.
SKYLINE ?= future
# skyline tileset: future or oldtown (make -B SKYLINE=oldtown)

OBJS = build/fzero.o build/hUGEDriver.o build/race.o

fzero.gb: $(OBJS)
	rgblink -o $@ -n fzero.sym $(OBJS)
	rgbfix -v -p 0xFF -m MBC5 -t FZEROCITY $@

# tiles, tilemap and per-line lookup tables
build/consts.inc: tools/gen_gfx.py
	@mkdir -p build
	python3 tools/gen_gfx.py build --skyline $(SKYLINE)

# the song is edited in hUGETracker; this is the tracker's own asm export
build/race.asm: music/race.uge tools/uge.py
	@mkdir -p build
	python3 tools/uge.py music/race.uge $@ --name race_song --bank 3

build/fzero.o: fzero.asm build/consts.inc $(wildcard include/*)
	rgbasm -I include -o $@ fzero.asm

build/race.o: build/race.asm
	rgbasm -I include -o $@ $<

build/hUGEDriver.o: hUGEDriver.asm $(wildcard include/*)
	@mkdir -p build
	rgbasm -o $@ hUGEDriver.asm

clean:
	rm -rf build fzero.gb fzero.sym

.PHONY: clean

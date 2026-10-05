# fsub: F-Zero style racer for Game Boy.  Needs rgbds and python3.
SONGS = race ocean wind port
OBJS = build/fzero.o build/hUGEDriver.o $(SONGS:%=build/%.o)

fzero.gb: $(OBJS)
	rgblink -o $@ -n fzero.sym $(OBJS)
	rgbfix -v -p 0xFF -m MBC5 -t FZEROCITY $@

# tiles, tilemap and per-line lookup tables
build/consts.inc: tools/gen_gfx.py
	@mkdir -p build
	python3 tools/gen_gfx.py build

# the tracks themselves
build/tracks.bin: tools/gen_tracks.py
	@mkdir -p build
	python3 tools/gen_tracks.py $@

# the songs are edited in hUGETracker; this is the tracker's own asm export
build/race.asm: music/race.uge tools/uge.py
	@mkdir -p build
	python3 tools/uge.py $< $@ --name race_song --bank 3
build/ocean.asm: music/ocean.uge tools/uge.py
	@mkdir -p build
	python3 tools/uge.py $< $@ --name ocean_song --bank 7
build/wind.asm: music/wind.uge tools/uge.py
	@mkdir -p build
	python3 tools/uge.py $< $@ --name wind_song --bank 8
build/port.asm: music/port.uge tools/uge.py
	@mkdir -p build
	python3 tools/uge.py $< $@ --name port_song --bank 9

build/fzero.o: fzero.asm build/consts.inc build/tracks.bin $(wildcard include/*)
	rgbasm -I include -o $@ fzero.asm

build/%.o: build/%.asm
	rgbasm -I include -o $@ $<

build/hUGEDriver.o: hUGEDriver.asm $(wildcard include/*)
	@mkdir -p build
	rgbasm -o $@ hUGEDriver.asm

clean:
	rm -rf build fzero.gb fzero.sym

.PHONY: clean

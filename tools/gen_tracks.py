#!/usr/bin/env python3
"""The tracks.  Each becomes a 512-byte block that fzero.asm copies into RAM when it is chosen:

    0    bend of each chunk (0 hard left .. 32 straight .. 64 hard right; +128 = "special
         tight": drawn the same, felt half as hard again)
    64   the same for the tunnel short cut
    128  pace of the field through each chunk (1/32 unit per frame; each rival adds its skill)
    192  what appears two chunks ahead on entering each chunk (see the codes below)
    256  scenery of each chunk (an index into the track's palette set)
    320  crosswind in each chunk (signed, 1/16 pixel per frame; positive blows to the right)
    384  skyline, palette set, chunk where the tunnel comes back up, chunks it cuts off
    388  things painted across the road: (first chunk it shows from, chunks it stays
         relevant, start, end, kind), ended by $FF

One lap is 64 chunks of 256 units.  usage: gen_tracks.py OUT.bin
"""
import math
import sys

MOUTH, B0, B1, B2, B3, DIRT_L, DIRT_R, PAD_L, PAD_R, HEAL_L, HEAL_R = range(1, 12)
PLAIN, DASH, JUMP, DARK = 0, 1, 2, 4            # painted bands (3 is unused)
TIGHT = 128
FUTURE, OLDTOWN, OCEAN, PLAINS = range(4)       # skylines, in gen_gfx.py's order
# sceneries are indexes into a palette set; 1 is always the roofed underpass
SET_CITY = 0                                    # 0 city, 1 underpass, 2 water
SET_FIELD = 1                                   # 0 wheat fields, 1 underpass, 2 city
START_LINE = [(0, 24, PLAIN), (24, 48, DARK), (48, 72, PLAIN)]
RECHARGE = {1: HEAL_L, 2: HEAL_L}               # two recharge patches on the left, after the line


def chunk(n, extra=0):
    return n * 256 + extra


TRACKS = [
    dict(  # 0  NEO CITY: a bit of everything
        skyline=FUTURE, palset=SET_CITY, exit=30, skip=3,
        bends=[(6, 32), (4, 44), (6, 32), (6, 4), (2, 32), (6, 60), (2, 18), (2, 46), (4, 32),
               (6, 12), (4, 32), (4, 50), (4, 16), (4, 44), (4, 32)],
        tunnel=[(24, 32), (4, 38), (4, 28), (32, 32)],
        scenes=[(38, 0), (8, 2), (6, 0), (6, 1), (6, 0)],
        wind=[(64, 0)],
        things={4: PAD_R, 7: B3, 8: B2,                 # launch pad; Barrier Bend
                12: MOUTH, 13: PAD_R,                   # the Fork: tunnel left or boost right
                16: DIRT_L, 18: DIRT_L, 20: DIRT_L,     # Dirt Hairpin: no inside line
                23: PAD_L,                              # Sucker Pad, then a clean hairpin to skid
                31: B0, 33: B3,                         # Barrier Chicane
                39: DIRT_L, 40: DIRT_R, 41: DIRT_L, 42: DIRT_R,   # Causeway Slalom
                49: PAD_L, 51: B3,                      # Pad Bend
                53: B1, 54: B2, 55: B1, 56: B2},        # the Underpass: hug a wall
        bands=START_LINE + [(chunk(12), chunk(12, 90), DASH), (chunk(35), chunk(35, 60), JUMP),
                                  (chunk(45), chunk(45, 90), DASH), (chunk(61), chunk(61, 90), DASH)]),
    dict(  # 1  BLUE DEEP: fast and flowing over the sea, boost pads on the outside of the waves
        skyline=OCEAN, palset=SET_CITY, exit=0, skip=0,
        bends=[(6, 32), (6, 46), (4, 16), (4, 48), (4, 32), (8, 10), (4, 32), (4, 50), (4, 14),
               (4, 50), (4, 14), (4, 32), (6, 44), (2, 32)],
        tunnel=[(64, 32)],
        scenes=[(4, 0), (56, 2), (4, 0)],               # harbour at the line, open water beyond
        wind=[(64, 0)],
        things={4: PAD_R, 8: PAD_L,
                20: DIRT_L, 21: DIRT_R, 22: DIRT_L,     # the Sandbars
                26: PAD_R, 30: PAD_L,                   # round the Long Left
                33: B1, 34: B2,                         # pick a side
                37: PAD_L, 41: PAD_R, 45: PAD_L, 49: PAD_R,   # the Waves: a pad outside each one
                55: DIRT_R,                             # just past the landing
                58: PAD_R},
        bands=START_LINE + [(chunk(32, 40), chunk(32, 130), DASH), (chunk(53), chunk(53, 60), JUMP),
                                  (chunk(62), chunk(62, 90), DASH)]),
    dict(  # 2  GOLD WIND: a simple fast lap, and a crosswind you have to lean into
        skyline=PLAINS, palset=SET_FIELD, exit=0, skip=0,
        bends=[(10, 32), (8, 52), (12, 32), (4, 16), (4, 48), (8, 32), (8, 52), (4, 20), (6, 32)],
        tunnel=[(64, 32)],
        scenes=[(64, 0)],
        wind=[(10, 10), (8, 4), (12, -12), (8, -4), (8, 12), (8, 4), (10, -9)],
        things={3: PAD_L, 5: DIRT_R, 7: DIRT_R,         # the wind carries you into the dirt
                13: B3,
                21: DIRT_L, 23: PAD_R, 24: DIRT_L, 27: DIRT_L,
                31: B0, 35: B3,
                40: DIRT_R, 42: PAD_L, 44: DIRT_R,
                49: B2, 55: B1,
                59: DIRT_L, 61: PAD_R},
        bands=START_LINE + [(chunk(19), chunk(19, 90), DASH), (chunk(39), chunk(39, 90), DASH),
                                  (chunk(62), chunk(62, 90), DASH)]),
    dict(  # 3  OLD PORT: tight and technical, with one hairpin tighter than anything else
        skyline=OLDTOWN, palset=SET_CITY, exit=0, skip=0,
        bends=[(4, 32), (4, 50), (2, 32), (4, 6), (2, 32), (6, 64 | TIGHT), (4, 32), (2, 16),
               (2, 48), (2, 16), (2, 48), (4, 32), (6, 4), (4, 32), (4, 56), (4, 8), (4, 46),
               (4, 32)],
        tunnel=[(64, 32)],
        scenes=[(26, 0), (8, 1), (30, 0)],              # the double chicane runs under the docks
        wind=[(64, 0)],
        things={6: B3, 11: DIRT_L,
                15: B0,                                 # last marker before the Tight One
                23: PAD_L,                              # and the reward for getting round it
                27: B3, 29: B0, 31: B3,                 # the Dock Chicane
                39: DIRT_L, 41: DIRT_L,
                45: PAD_R, 49: B2, 53: B1, 57: DIRT_R},
        bands=START_LINE + [(chunk(35), chunk(35, 90), DASH), (chunk(61), chunk(61, 90), DASH)]),
]


def spread(sections, what):
    out = []
    for n, v in sections:
        out += [v] * n
    assert len(out) == 64, (what, len(out))
    return out


def pace(bend):
    """What the best rival does through a chunk, less the 50 its skill adds back.  The rivals
    corner about 15% faster than the player can hold a clean line (see PushScale in
    fzero.asm): keeping up through the bends means leaning on the rail, which costs health."""
    b = abs((bend & 127) - 32) * (1.5 if bend & TIGHT else 1)
    limit = 8.3 if b < 2 else min(8.3, 8 * math.sqrt(12.3 / b))
    ace = min(7.8, 1.15 * limit)
    if b >= 6:
        ace = min(ace, 7.5)
    return max(60, int(round(ace * 32)) - 50)


def block(t):
    bends = spread(t["bends"], "bends")
    out = bytearray(bends)
    out += bytes(spread(t["tunnel"], "tunnel"))
    out += bytes(pace(b) for b in bends)
    things = [0] * 64
    for where, what in {**RECHARGE, **t["things"]}.items():
        assert things[(where - 2) % 64] == 0
        things[(where - 2) % 64] = what           # it shows up two chunks before it sits
    out += bytes(things)
    out += bytes(spread(t["scenes"], "scenes"))
    out += bytes(w & 255 for w in spread(t["wind"], "wind"))
    out += bytes((t["skyline"], t["palset"], t["exit"], t["skip"]))
    for start, end, kind in t["bands"]:
        out += bytes((((start // 256) - 8) & 63, (end - 1) // 256 - start // 256 + 9,
                      start & 255, start >> 8, end & 255, end >> 8, kind))
    out.append(0xFF)
    assert len(out) <= 512
    return bytes(out) + bytes(512 - len(out))


if __name__ == "__main__":
    with open(sys.argv[1], "wb") as f:
        for t in TRACKS:
            f.write(block(t))
    print(f"gen_tracks: {len(TRACKS)} tracks")

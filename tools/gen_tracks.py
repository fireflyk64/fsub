#!/usr/bin/env python3
"""The tracks.  Each becomes a 512-byte block that fzero.asm copies into RAM when it is chosen:

    0    bend of each chunk (0 hard left .. 32 straight .. 64 hard right; +128 = "special
         tight": drawn the same, felt half as hard again)
    64   the same for the tunnel short cut
    128  pace of the field through each chunk (1/16 unit per frame; each rival adds its skill)
    192  what appears two chunks ahead on entering each chunk (see the codes below)
    256  scenery of each chunk (an index into the track's palette set)
    320  crosswind in each chunk (signed, 1/16 pixel per frame; positive blows to the right)
    384  skyline, palette set, chunk where the tunnel comes back up, chunks it cuts off
    388  things painted across the road: (first chunk it shows from, chunks it stays
         relevant, start, end, kind), ended by $FF

One lap is 64 chunks of 256 units.  usage: gen_tracks.py OUT.bin
"""
import math
import os
import re
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


# A course is straights and corners, in chunks:
#   ("S", n)              n chunks of straight
#   ("R", level, n)       a right-hand corner n chunks long; ("L", ...) a left-hand one
#   ("RT", level, n)      the same, "special tight": felt half as hard again
# A corner turns level * n / 16 quarter-turns: level 16 for one chunk is 90 degrees, 32 for
# one chunk is a 180-degree hairpin, 8 for two chunks a 90-degree sweeper.  A lap must turn
# exactly once round (so three rights and a left come out even), and corners in opposite
# directions need a straight between them.  At racing speed a chunk takes about half a second.
QUARTER = 16                                    # level-chunks in a 90-degree turn


def course(sections):
    out, heading, last = [], 0, None
    for s in sections:
        if s[0] == "S":
            out += [32] * s[1]
            last = None
            continue
        kind, level, n = s
        assert level in (8, 16, 24, 32), s
        right = kind[0] == "R"
        assert last in (None, right), f"{s}: opposite corners need a straight between them"
        out += [(32 + level if right else 32 - level) | (TIGHT if kind.endswith("T") else 0)] * n
        heading += level * n if right else -level * n
        last = right
    assert len(out) == 64, f"lap is {len(out)} chunks, not 64"
    assert abs(heading) == 4 * QUARTER, f"lap turns {heading * 90 / QUARTER} degrees, not 360"
    return out


TRACKS = [
    dict(  # 0  NEO CITY: a bit of everything
        skyline=FUTURE, palset=SET_CITY, exit=28, skip=3,
        course=[("S", 6), ("R", 16, 1), ("S", 4), ("L", 16, 1), ("S", 6), ("R", 32, 1), ("S", 3),
                ("R", 16, 1), ("S", 3), ("L", 16, 1), ("S", 7), ("R", 16, 1),
                ("S", 3), ("L", 8, 2), ("S", 6), ("R", 16, 1), ("S", 3), ("L", 16, 1), ("S", 4),
                ("R", 16, 1), ("S", 2), ("R", 16, 1), ("S", 5)],
        scenes=[(40, 0), (6, 2), (4, 0), (5, 1), (9, 0)],
        wind=[(64, 0)],
        things={4: PAD_R,                               # launch pad
                9: B0,                                  # brake marker before the first left
                13: MOUTH,                              # the Fork, a chunk past the corner: the
                                                        # tunnel skips straight road to the hairpin
                14: PAD_R,                              # or a boost on the right
                18: DIRT_R,                             # Dirt Hairpin: no inside line (it turns right)
                20: PAD_L, 24: B1,
                31: B0, 33: B3,                         # Barrier Straight
                41: DIRT_L, 42: DIRT_R, 43: DIRT_L, 44: DIRT_R,   # Causeway Slalom
                48: PAD_R,
                52: B1, 53: B2, 54: B1,                 # the Underpass: hug a wall
                60: PAD_L},
        bands=START_LINE + [(chunk(7), chunk(7, 90), DASH), (chunk(36), chunk(36, 60), JUMP),
                            (chunk(40), chunk(40, 90), DASH), (chunk(61), chunk(61, 90), DASH)]),
    dict(  # 1  BLUE DEEP: long sweepers over the sea, boost pads on the outside of the waves
        skyline=OCEAN, palset=SET_CITY, exit=0, skip=0,
        course=[("S", 6), ("R", 8, 2), ("S", 3), ("L", 8, 2), ("S", 3), ("R", 16, 2), ("S", 4),
                ("L", 8, 2), ("S", 3), ("R", 8, 2), ("S", 2), ("L", 8, 2), ("S", 2), ("R", 8, 2),
                ("S", 2), ("L", 8, 2), ("S", 4), ("R", 16, 2), ("S", 9), ("R", 8, 2), ("S", 6)],
        scenes=[(4, 0), (56, 2), (4, 0)],               # harbour at the line, open water beyond
        wind=[(64, 0)],
        things={4: PAD_R, 9: PAD_L,
                19: DIRT_L, 20: DIRT_R, 21: DIRT_L,     # the Sandbars
                25: PAD_R,
                29: PAD_L, 33: PAD_R, 37: PAD_L, 41: PAD_R,   # the Waves: a pad outside each one
                48: B1, 49: B2,                         # pick a side
                55: DIRT_R, 59: PAD_R},
        bands=START_LINE + [(chunk(18), chunk(18, 90), DASH), (chunk(52), chunk(52, 60), JUMP),
                            (chunk(61), chunk(61, 90), DASH)]),
    dict(  # 2  GOLD WIND: long straights, a few big corners, and a crosswind to lean into
        skyline=PLAINS, palset=SET_FIELD, exit=0, skip=0,
        course=[("S", 10), ("R", 16, 2), ("S", 10), ("L", 8, 2), ("S", 4), ("R", 8, 2), ("S", 10),
                ("R", 16, 2), ("S", 10), ("L", 16, 1), ("S", 4), ("R", 16, 1), ("S", 6)],
        scenes=[(64, 0)],
        wind=[(10, 10), (2, 0), (10, -12), (8, 0), (10, 12), (2, 0), (10, -10), (12, 8)],
        things={3: PAD_L, 5: DIRT_R, 7: DIRT_R,         # the wind carries you into the dirt
                14: DIRT_L, 16: PAD_R, 18: DIRT_L, 20: DIRT_L,
                27: B0, 31: B3,
                34: DIRT_R, 36: PAD_L, 38: DIRT_R,
                45: B2, 47: DIRT_L, 49: PAD_R,
                55: B1, 60: DIRT_L},
        bands=START_LINE + [(chunk(24), chunk(24, 90), DASH), (chunk(42), chunk(42, 90), DASH),
                            (chunk(62), chunk(62, 90), DASH)]),
    dict(  # 3  OLD PORT: sharp corners close together, and one tighter than anything else
        skyline=OLDTOWN, palset=SET_CITY, exit=0, skip=0,
        course=[("S", 4), ("R", 24, 1), ("S", 2), ("L", 24, 1), ("S", 3), ("RT", 32, 1), ("S", 4),
                ("L", 16, 1), ("S", 2), ("R", 16, 1), ("S", 2), ("L", 16, 1), ("S", 2),
                ("R", 16, 1), ("S", 4), ("R", 32, 1), ("S", 3), ("L", 24, 1), ("S", 3),
                ("R", 24, 1), ("S", 4), ("L", 16, 1), ("S", 3), ("R", 16, 1), ("S", 16)],
        scenes=[(16, 0), (10, 1), (38, 0)],             # the dock chicane runs under the docks
        wind=[(64, 0)],
        things={9: B0,                                  # last marker before the Tight One (11)
                14: PAD_L,                              # and the reward for getting round it
                18: B3, 21: B0, 24: B3,                 # the Dock Chicane: a chunk past each exit
                28: DIRT_R,                             # inside of the hairpin at 30
                33: PAD_R, 41: B2, 45: DIRT_L, 50: B1, 56: PAD_L},
        bands=START_LINE + [(chunk(49), chunk(49, 90), DASH), (chunk(59), chunk(59, 90), DASH)]),
]


def spread(sections, what):
    out = []
    for n, v in sections:
        out += [v] * n
    assert len(out) == 64, (what, len(out))
    return out


# how hard bends push the car, as the game has it
PUSH_K = int(re.search(r"DEF PUSH_K +EQU +(\d+)", open(os.path.join(os.path.dirname(__file__), "..", "fzero.asm")).read())[1])


ACE_STRAIGHT = 8.4                              # the best rival's speed on the straight


def corner_speed(b, n):
    """The fastest a good driver takes n chunks of bend b, letting it throw the car no more
    than 40 pixels out: the push is PUSH_K * 16/1024 * speed^2 * bend / 512 pixels a frame,
    against 1.5 of steering (see PushScale in fzero.asm)."""
    push, v = PUSH_K * 16 / 1024 / 512, 12.0
    while v > 2 and (push * v * v * b - 1.5) * 256 * n / v > 40:
        v -= 0.05
    return v


def paces(bends):
    """What the best rival does through each chunk (1/16 unit a frame), less the 25 its
    skill adds back: flat out on the straight, and each corner as a good driver takes it."""
    out = []
    for i, bend in enumerate(bends):
        b = abs((bend & 127) - 32) * (1.5 if bend & TIGHT else 1)
        start, end = i, i + 1                     # the whole of the corner this chunk is in
        while bends[(start - 1) % 64] == bend and end - start < 8:
            start -= 1
        while bends[end % 64] == bend and end - start < 8:
            end += 1
        n = end - start
        ace = ACE_STRAIGHT if b < 2 else min(ACE_STRAIGHT, corner_speed(b, n))
        out.append(int(round(ace * 16)) - 25)
    return out


def block(t):
    bends = course(t["course"])
    if t["skip"]:                                 # the tunnel's short cut must jump straight road
        mouth = next(c for c, w in t["things"].items() if w == MOUTH)
        assert all(b == 32 for b in bends[mouth:mouth + t["skip"] + 2]), "the short cut skips a corner"
    out = bytearray(bends)
    out += bytes(bends)                           # underground the course is the same shape
    out += bytes(paces(bends))
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

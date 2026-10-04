#!/usr/bin/env python3
"""Generate the graphics and lookup tables for fzero.asm (the F-Zero style city POC).

The whole ground is ONE static tilemap drawn in perspective.  It never changes.  All the
motion comes from two registers rewritten every scanline during HBlank:

  BGP  what the 4 colour numbers look like on that line.  A line's depth decides which part
       of a building (wall / roof / street) is passing under it, so buildings slide toward
       the viewer although no tile is ever redrawn.
  SCX  slides that line sideways, which bends the road.

Colour numbers on the ground:  0 street/void (dark)   1 road surface (never animates)
                               2 building set A + road bumpers + centre dashes
                               3 building set B (staggered against A)

usage: gen_gfx.py OUTDIR [--skyline future|oldtown] [--preview DIR]
"""
import os
import sys

W = 256                 # tilemap width in pixels
HORIZON = 40            # first ground line; lines 0..39 are sky
GROUND = 104            # ground lines the perspective is built for, d = 1 (horizon) .. 104
VISIBLE = 96            # ...of which the last 8 are behind the status bar
HUD_LINE = HORIZON + VISIBLE    # first line of the status bar (a window over the picture)
SKY_STATIC = 32         # sky lines 0..31 share one palette and scroll: no HBlank work there
CX = 128                # vanishing point, map pixel
DEPTH = 16640.0         # z(d) = DEPTH / d, in world units (1 unit = 1 pixel on the bottom line)
VIEW_X = 48             # SCX when the road is straight: shows map x 48..207
STAR_ROWS = 16          # top lines hold only stars (and scroll at half rate)
MAX_BEND = 80           # pixels the horizon end of the road can slide either way; past 48
                        # the far rows wrap round the 256-pixel map, which only shows as
                        # one more street in the distant city
LEVELS = 32             # bend steps each side (65 tables)
SHEAR_MAX = 22          # pixels the bottom line can slide either way when the camera moves

ROAD = 56               # road half width in world units
BUMPER = 6              # bumper strip just inside the road edge
GAP = 10                # dark void between road and city


def z_of(d):
    return DEPTH / d


# ----------------------------------------------------------------------------------------
# Lateral layout: which colour number is at world x = u.  Baked into the tilemap.
# ----------------------------------------------------------------------------------------
def hash8(n):
    n = (n * 2654435761) & 0xFFFFFFFF
    return (n >> 13) & 0xFF


def city(u, detail):
    """detail: 0 near (streets + split lots), 1 mid (blocks), 2 far (districts)."""
    if detail == 1.5:                             # streets too thin to draw: merged blocks
        if u % 256 < 30:
            return 0
        return 2 if int(u // 64) & 1 else 3
    av = u % 256
    if av < 30:                                   # avenue running to the horizon
        return 1 if 12 <= av < 18 and detail < 2 else 0   # with a static pipeline down it
    if detail == 2:
        return 2 if hash8(int(u // 128) + 77) & 1 else 3
    col = int(u // 32)
    w = u % 32
    h = hash8(col)
    if w < 8:
        return 0                                  # street between blocks
    if detail == 0 and h % 5 == 0 and 18 <= w < 21:
        return 0                                  # alley splitting a block into two lots
    if detail == 0 and h % 5 == 0 and w >= 21:
        return 3 if h & 1 else 2
    return 2 if h & 1 else 3


def lateral(u, detail):
    au = abs(u)
    if au < ROAD:
        if au < 2 and detail == 0:
            return 2                              # centre dashes
        if au >= ROAD - BUMPER and detail < 2:
            return 2                              # bumpers
        return 1
    if au < ROAD + GAP:
        return 0
    return city(u + 4000, detail)


def ground_row(d):
    """Colour numbers for the 256 map pixels of ground line d, majority-filtered."""
    scale = GROUND / d                            # world units per pixel
    detail = 0 if scale < 2.2 else (1 if scale < 4.5 else (1.5 if scale < 9 else 2))
    row = []
    for x in range(W):
        votes = [0, 0, 0, 0]
        n = 7 if scale > 1.5 else 1
        for s in range(n):
            u = (x + (s + 0.5) / n - CX) * scale
            votes[lateral(u, detail)] += 1
        # ties go to the more interesting colour so thin features survive a little longer
        best = max(range(4), key=lambda i: (votes[i], i))
        row.append(best)
    return row


# ----------------------------------------------------------------------------------------
# Depth layout: what each colour number looks like at world depth v.  Becomes BGP tables.
# Shades: 0 white, 1 light grey, 2 dark grey, 3 black.
# ----------------------------------------------------------------------------------------
def depth_strip():
    """256 world units of city along the direction of travel -> (shadeA, shadeB) per unit."""
    a, b = [], []

    def block(dst, wall, roof, street, roof_shade, seam_shade, wall_shade=2):
        dst += [wall_shade] * wall
        for i in range(roof):
            dst.append(seam_shade if roof > 20 and roof // 2 <= i < roof // 2 + 2 else roof_shade)
        dst += [3] * street

    a += [3] * 24                                 # cross avenue (both sets dark)
    for roof in (19, 27, 27, 19, 35, 27):
        block(a, 5, roof, 8, 0, 1)
    b += [3] * 24
    b += [3] * 8
    for i, roof in enumerate((27, 19, 35, 19, 27, 27)):
        block(b, 5, roof, 8 if i < 5 else 0, 2, 1, 1)   # dim roofs, lit near wall
    assert len(a) == 256 and len(b) == 256, (len(a), len(b))
    return a, b


def smooth(strip, window):
    """Box-filter a cyclic strip of shades: the distant version of the same city."""
    n = len(strip)
    out = []
    for i in range(n):
        tot = sum(strip[(i + k - window // 2) % n] for k in range(window))
        out.append(int(tot / window + 0.5))
    return out


def bgp(s0, s1, s2, s3):
    return s0 | (s1 << 2) | (s2 << 4) | (s3 << 6)


def pal_tables():
    """List of (name, 256 BGP bytes).  Near tables step 1 world unit per entry, far ones 16."""
    a, b = depth_strip()
    tabs = []
    for name, win in (("Near0", 1), ("Near1", 5), ("Near2", 11), ("Near3", 21)):
        sa, sb = smooth(a, win), smooth(b, win)
        tabs.append((name, [bgp(3, 1, sa[i], sb[i]) for i in range(256)]))
    # Far tables: one entry = 16 units, so the 256-unit strip above repeats every 16 entries.
    far0, far1 = [], []
    for i in range(256):
        avenue = i % 16 == 0
        far0.append(bgp(3, 1, 3, 3) if avenue else bgp(3, 1, 1, 2))
        bright = (i // 48) % 2 == 0               # districts ~768 units long
        far1.append(bgp(3, 1, 1, 2) if bright else bgp(3, 1, 2, 3))
    tabs.append(("Far0", far0))
    tabs.append(("Far1", far1))
    tabs.append(("Far2", [bgp(2, 1, 1, 1)] * 256))     # horizon haze, static
    return tabs


# (first d, last d, table, uses coarse phase)
BANDS = [(1, 3, "Far2", True), (4, 11, "Far1", True), (12, 25, "Far0", True),
         (26, 35, "Near3", False), (36, 49, "Near2", False), (50, 69, "Near1", False),
         (70, 104, "Near0", False)]


def row_phase():
    """Per screen line: its depth, in the units of the table its band uses."""
    out = [0] * 256
    for lo, hi, _name, coarse in BANDS:
        for d in range(lo, hi + 1):
            z = int(z_of(d) + 0.5)
            out[HORIZON + d - 1] = ((z >> 4) if coarse else z) & 255
    return out


# ----------------------------------------------------------------------------------------
# Sky
# ----------------------------------------------------------------------------------------
# Sky colour numbers: 0 sky (shade set per line), 1 building, 2 lights, 3 stars / rim light
# A skyline is a row of building stamps whose widths are whole tiles, so repeats cost nothing.
# Each shape answers "is (x, height above the ground) inside me, and is it a light?".


def old_building(style, w, h):
    """Twentieth-century blocks with rows of lit windows (the "oldtown" set)."""
    def shape(lx, hb):
        ly = h - 1 - hb
        if ly < 0 or lx >= w - 1:
            return None
        inside = True
        if style == "spire":
            inside = ly >= 8 or lx == 3 or (ly >= 4 and 2 <= lx <= 4)
        elif style == "dome":
            inside = ly >= 4 or abs(lx - (w - 1) / 2 + 0.5) < 3 + ly * 2.5
        elif style == "twin":
            inside = ly >= 6 or lx < 5 or lx > w - 7
        elif style == "tower":
            inside = ly >= 10 or 4 <= lx <= w - 6
            if ly < 3:
                inside = lx == w // 2 - 1
        if not inside:
            return None
        return 2 if ly > 2 and hb % 3 == 0 and lx % 2 == 0 and (lx + hb // 3) % 6 else 1
    return shape


def future_building(style, w):
    """Needles, saucers, domes and arches with strips of light (the "future" set)."""
    c = (w - 1) / 2.0

    def shape(lx, hb):
        dx = abs(lx - c)
        if style == "needle":
            if hb < 4:
                return 1 if dx <= 2.5 else None
            if hb in (11, 12):
                return (2 if hb == 12 else 1) if dx <= 3.5 else None
            if hb < 17:
                return 1 if dx <= 1 else None
            return 1 if hb < 24 and lx == 3 else None
        if style == "taper":
            if hb >= 20:
                return 1 if hb < 23 and lx == int(c) else None
            if dx > 2.5 + (1 - hb / 20.0) * (w / 2.0 - 3.5):
                return None
            return 2 if dx < 1 and hb % 4 and 2 < hb < 17 else 1
        if style == "saucer":
            if hb >= 18:
                return 1 if hb < 21 and lx == int(c) else None
            if (dx / 7.5) ** 2 + ((hb - 14) / 3.6) ** 2 <= 1:
                return 2 if hb == 14 and lx % 2 == 0 else 1
            return 1 if hb < 12 and dx <= 1 else None
        if style == "dome":
            if hb >= 11:
                return 1 if hb < 15 and lx == int(c) else None
            if (dx / 11.5) ** 2 + (hb / 11.0) ** 2 > 1:
                return None
            return 2 if hb == 3 and lx % 2 else 1
        if style == "arch":
            if (dx / 11.5) ** 2 + (hb / 14.0) ** 2 > 1 or (dx / 7.5) ** 2 + (hb / 9.0) ** 2 <= 1:
                return None
            return 2 if hb == 12 and lx % 2 else 1
        if style == "low":
            if 6 <= lx <= 9 and hb < 13:
                return 2 if lx == 8 and hb in (8, 10) else 1
            if hb >= 7 or dx > 15.5 - max(0, hb - 3) * 1.5:
                return None
            return 2 if hb == 4 and lx % 3 else 1
        return None
    return shape


SKYLINES = {
    "oldtown": [(w, old_building(st, w, h)) for w, h, st in (
        (16, 14, "slab"), (8, 16, "spire"), (16, 18, "twin"), (24, 10, "dome"),
        (16, 24, "tower"), (8, 12, "slab"), (24, 12, "slab"), (8, 22, "spire"),
        (24, 10, "dome"), (16, 24, "tower"), (8, 12, "slab"), (16, 18, "twin"),
        (24, 12, "slab"), (8, 22, "spire"), (16, 14, "slab"), (8, 16, "spire"),
        (8, 12, "slab"), (8, 22, "spire"))],
    "future": [(w, future_building(st, w)) for st, w in (
        ("taper", 16), ("needle", 8), ("dome", 24), ("saucer", 16), ("low", 32),
        ("needle", 8), ("arch", 24),
        ("saucer", 16), ("low", 32), ("needle", 8), ("taper", 16), ("arch", 24),
        ("needle", 8), ("dome", 24))],
}


def sky_pixels(skyline):
    px = [[0] * W for _ in range(HORIZON)]
    # Stars: three one-pixel patterns reused all over the upper sky (cheap in tiles).
    spots = ((2, 1), (6, 3), (3, 4))
    for i in range(40):
        tx, ty, kind = hash8(i * 13 + 5) % 32, hash8(i * 29 + 1) % 2, i % 3
        ox, oy = spots[kind]
        if not any(px[ty * 8 + r][tx * 8 + c] for r in range(8) for c in range(8)):
            px[ty * 8 + oy][tx * 8 + ox] = 3
    x = 0
    stamps = SKYLINES[skyline]
    assert sum(w for w, _ in stamps) == W
    for w, shape in stamps:
        for hb in range(HORIZON - STAR_ROWS):
            for lx in range(w):
                c = shape(lx, hb)
                if c is None:
                    continue
                if c == 1 and (lx == 0 or shape(lx - 1, hb) is None):
                    c = 3                         # lit left edge
                px[HORIZON - 1 - hb][x + lx] = c
        x += w
    return px


def sky_bgp():
    """BGP for lines 0..39.  Lines 0..SKY_STATIC are one palette (dark sky, black buildings,
    white lights and stars); below that the sky brightens to a glow at the horizon."""
    out = []
    for y in range(HORIZON):
        if y <= SKY_STATIC:
            out.append(bgp(2, 3, 0, 0))
        else:
            sky = 2 if y < 35 and y % 2 else (1 if y < 38 else 0)
            out.append(bgp(sky, 3, 0, 2))
    return out


# ----------------------------------------------------------------------------------------
# Bend tables and car sprite
# ----------------------------------------------------------------------------------------
def bend_tables():
    tabs = []
    for lv in range(-LEVELS, LEVELS + 1):
        row = []
        for d in range(1, GROUND + 1):
            g = ((GROUND - d) / (GROUND - 1.0)) ** 2
            off = int(round(MAX_BEND * g * lv / LEVELS))
            row.append((VIEW_X - off) & 255)
        tabs.append(row)
    return tabs


CAR = """
.......33.......
......3113......
......3113......
.....311113.....
.....312213.....
....31222213....
....31222213....
...3113223113...
..311113311113..
.31111133111113.
3111111331111113
3122211111122213
3122231111322213
.33331333313333.
....313..313....
................
"""

SHADOW = """
..222222
.2222222
.2222222
..222222
"""

SHADOW_SMALL = """
........
....2222
....2222
........
"""


def pack_object(rows):
    """16 rows x 8 columns of colour numbers -> the two tiles of an 8x16 object."""
    out = bytearray()
    for row in rows:
        lo = hi = 0
        for v in row:
            lo = (lo << 1) | (v & 1)
            hi = (hi << 1) | (v >> 1)
        out += bytes((lo, hi))
    return bytes(out)


def car_image():
    """The 16x16 car.  It is symmetrical, so only the left half is stored; the right half is
    the same object mirrored.  Every car on the track uses these tiles: liveries are palettes."""
    rows = CAR.strip().split("\n")
    assert len(rows) == 16 and all(len(r) == 16 and r == r[::-1] for r in rows)
    return [[0 if c == "." else int(c) for c in r] for r in rows]


RIVAL_SIZES = (12, 8, 4)        # smaller copies of the car for rivals further up the road
RIVAL_FROM = (80, 52, 30, 8)    # ground line d where the 16, 12, 8 and 4 pixel cars start
RIVAL_LANES = (-36, -12, 12, 36)


def shrink(img, n):
    """Scale the 16x16 car down to n x n, keeping the outline where it can."""
    out = [[0] * n for _ in range(n)]
    for y in range(n):
        for x in range(n):
            votes = [0, 0, 0, 0]
            for yy in range(y * 16 // n, max(y * 16 // n + 1, (y + 1) * 16 // n)):
                for xx in range(x * 16 // n, max(x * 16 // n + 1, (x + 1) * 16 // n)):
                    votes[img[yy][xx]] += 1
            solid = sum(votes[1:])
            if solid * 2 >= sum(votes):
                out[y][x] = max((1, 2, 3), key=lambda c: (votes[c], c == 3))
    return out


def small_car_objects():
    """8x16 objects for the shrunken cars, each drawn sitting on the bottom row."""
    objs = []
    for n in RIVAL_SIZES:
        img = shrink(car_image(), n)
        obj = [[0] * 8 for _ in range(16)]
        for y in range(n):
            for x in range(n):
                if n > 8:                         # left half only, against the right edge
                    if x < n // 2:
                        obj[16 - n + y][8 - n // 2 + x] = img[y][x]
                else:                             # whole car, centred
                    obj[16 - n + y][(8 - n) // 2 + x] = img[y][x]
        objs.append(obj)
    return objs


def car_tiles():
    out = bytearray(pack_object([r[:8] for r in car_image()]))
    for art in (SHADOW, SHADOW_SMALL):            # left halves; the right is the mirror image
        shadow = [[0 if c == "." else int(c) for c in r] for r in art.strip().split("\n")]
        out += pack_object(shadow + [[0] * 8] * 12)
    return bytes(out)


def rival_lane_tables():
    """For each rival lane: ground line d -> pixels from the road centre."""
    return [int(round(u * d / GROUND)) & 255 for u in RIVAL_LANES for d in range(128)]


# Road objects are sprites drawn at a few sizes and swapped as they come closer.
MOUTH_SIZES = ((16, 8), (32, 12), (40, 16))              # tunnel mouth, width x height
MOUTH_FROM = (0, 48, 80)                                 # ground line d each size starts at
LANE = -28              # centre of the left lane, world units from the centre line
SPAWN_DIST = 1024       # how far ahead road objects appear
CAR_D = 88              # ground line d where an object reaches the car


def mouth_image(w, h):
    """A dark ramp going down into the road: lit rim at the far end and sides, open near end."""
    img = [[0] * w for _ in range(16)]

    def inside(x, y):
        half = (0.74 + 0.26 * y / max(1, h - 1)) * w / 2.0
        return 0 <= y < h and abs(x + 0.5 - w / 2.0) <= half

    for y in range(h):
        for x in range(w):
            if not inside(x, y):
                continue
            rim = y == 0 or not inside(x - 1, y) or not inside(x + 1, y)
            c = 1 if rim else (2 if h >= 8 and y % 3 == 2 else 3)
            img[16 - h + y][x] = c                # bottom-aligned in the 8x16 objects
    return img


def mouth_tiles():
    """Left halves only (plus the centre column of the 40-wide one); the rest is mirrored."""
    out = bytearray()
    for w, h in MOUTH_SIZES:
        img = mouth_image(w, h)
        for col in range((w // 8 + 1) // 2):
            out += pack_object([r[col * 8:col * 8 + 8] for r in img])
    return bytes(out)


def dist_to_line():
    """Distance ahead (in steps of 8 units) -> ground line d it appears on (255 = behind us)."""
    out = []
    for i in range(256):
        d = int(round(DEPTH / (i * 8 + 4)))
        out.append(d if d <= GROUND else 255)
    return out


def lane_offsets():
    """Ground line d -> how far the lane centre is from the road centre there, in pixels."""
    return [int(round(LANE * d / GROUND)) & 255 for d in range(128)]


def tunnel_pal_tables():
    """Inside the tunnel: black walls with ribs of light sweeping past, same road."""
    a = [0 if i % 64 < 6 else (2 if i % 64 < 10 else 3) for i in range(256)]
    b = [1 if i % 64 < 6 else 3 for i in range(256)]
    tabs = []
    for name, win in (("TNear0", 1), ("TNear1", 5), ("TNear2", 11), ("TNear3", 21)):
        sa, sb = smooth(a, win), smooth(b, win)
        tabs.append((name, [bgp(3, 1, sa[i], sb[i]) for i in range(256)]))
    tabs.append(("TFar", [bgp(3, 1, 3, 3)] * 256))
    return tabs


def darker(v, n):
    """A BGP value with every colour n shades darker."""
    return bgp(*[min(3, ((v >> (i * 2)) & 3) + n) for i in range(4)])


def with_fades(data):
    """A table followed by the same table one and two shades darker, for fading out."""
    return [darker(v, n) for n in (0, 1, 2) for v in data]


def shear_tables():
    """Camera moved sideways: lines slide in proportion to how near they are."""
    return [[int(round(s * d / GROUND)) & 255 for d in range(1, GROUND + 1)]
            for s in range(-SHEAR_MAX, SHEAR_MAX + 1)]


# ----------------------------------------------------------------------------------------
OBJ_RESERVE = 24        # tiles kept free for sprites at the end of the $8000 block


# Status bar glyphs: colour 2 is white, 1 dark grey, 0 black under HUD_BGP.
HUD_BGP = bgp(3, 2, 0, 1)
FONT = {
    "1": ("..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."),
    "2": (".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"),
    "3": ("####.", "....#", "....#", ".###.", "....#", "....#", "####."),
    "4": ("...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."),
    "5": ("#####", "#....", "####.", "....#", "....#", "#...#", ".###."),
    "6": (".###.", "#....", "#....", "####.", "#...#", "#...#", ".###."),
    "7": ("#####", "....#", "...#.", "..#..", "..#..", "..#..", "..#.."),
    "8": (".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."),
    "P": ("####.", "#...#", "#...#", "####.", "#....", "#....", "#...."),
    "L": ("#....", "#....", "#....", "#....", "#....", "#....", "#####"),
    "SLASH": ("....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."),
}
HUD_ORDER = ["BLANK", "1", "2", "3", "4", "5", "6", "7", "8", "P", "L", "SLASH",
             "FULL", "HALF", "EMPTY"]


def hud_glyph(name):
    px = [[0] * 8 for _ in range(8)]
    if name in FONT:
        for y, row in enumerate(FONT[name]):
            for x, c in enumerate(row):
                if c == "#":
                    px[y][1 + x] = 2
    elif name != "BLANK":                         # a cell of the health bar
        lit = {"FULL": 7, "HALF": 4, "EMPTY": 0}[name]
        for y in range(1, 7):
            for x in range(7):
                px[y][x] = 2 if x < lit else 1
    data = bytearray()
    for row in px:
        lo = hi = 0
        for v in row:
            lo = (lo << 1) | (v & 1)
            hi = (hi << 1) | (v >> 1)
        data += bytes((lo, hi))
    return bytes(data)


def build(skyline):
    """Draw everything, cut it into tiles and spread those over the three VRAM blocks.

    The background can only name 256 tiles at once, but LCDC bit 4 picks which block tile
    numbers 0-127 come from.  Flipping it part way down the screen gives the picture up to
    384 tiles: block $8000 for the upper part, $9000 for the lower part, and $8800
    (numbers 128-255) visible to both.
    """
    sky = sky_pixels(skyline)
    ground = [ground_row(d) for d in range(1, GROUND + 1)]
    pixels = sky + ground                         # 144 rows x 256
    bends = bend_tables()

    # Map columns that can never reach the screen on a given tile row are "don't care".
    slots = []
    for ty in range(18):
        for tx in range(32):
            need = False
            for y in range(ty * 8, ty * 8 + 8):
                if y < HORIZON:
                    need = True
                    break
                if y >= HUD_LINE:                 # behind the status bar
                    break
                d = y - HORIZON + 1
                reach = abs(VIEW_X - bends[0][d - 1]) + int(SHEAR_MAX * d / GROUND + 1)
                if tx * 8 + 7 >= VIEW_X - reach and tx * 8 <= VIEW_X + 159 + reach:
                    need = True
                    break
            if not need:
                slots.append(None)
                continue
            data = bytearray()
            for y in range(ty * 8, ty * 8 + 8):
                lo = hi = 0
                for x in range(tx * 8, tx * 8 + 8):
                    v = pixels[y][x]
                    lo = (lo << 1) | (v & 1)
                    hi = (hi << 1) | (v >> 1)
                data += bytes((lo, hi))
            slots.append(bytes(data))

    # The status bar is a window over the bottom lines, so its glyphs live with the lower tiles.
    glyphs = {name: hud_glyph(name) for name in HUD_ORDER}

    best = None
    for split in (8,):                            # first tile row drawn from the $9000 block:
        # line 64, which the HBlank handler can spot with a single mask (see fzero.asm)
        top = {t for t in slots[:split * 32] if t}
        bot = {t for t in slots[split * 32:] if t} | set(glyphs.values())
        cap_top = 128 - OBJ_RESERVE
        only_top, only_bot = sorted(top - bot), sorted(bot - top)
        shared = sorted(top & bot) + only_top[cap_top:] + only_bot[128:]
        if best is None or len(shared) < len(best[3]):
            best = (split, only_top[:cap_top], only_bot[:128], shared)
    split, blk8000, blk9000, blk8800 = best
    total = len(blk8000) + len(blk9000) + len(blk8800)
    print(f"gen_gfx: {total} background tiles: {len(blk8000)} upper + {len(blk9000)} lower"
          f" + {len(blk8800)}/128 shared, split at line {split * 8}")
    if len(blk8800) > 128:
        sys.exit("too many tiles")

    tilemap = []
    for i, t in enumerate(slots):
        own = blk8000 if i < split * 32 else blk9000
        if t is None:
            tilemap.append(0)
        elif t in blk8800:
            tilemap.append(128 + blk8800.index(t))
        else:
            tilemap.append(own.index(t))
    hud = {name: 128 + blk8800.index(t) if t in blk8800 else blk9000.index(t)
           for name, t in glyphs.items()}
    return pixels, (blk8000, blk9000, blk8800), tilemap, bends, split * 8, hud


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    skyline = sys.argv[sys.argv.index("--skyline") + 1] if "--skyline" in sys.argv else "future"
    pixels, blocks, tilemap, bends, split_line, hud = build(skyline)
    tabs = pal_tables()
    if "--preview" in sys.argv:
        preview(sys.argv[sys.argv.index("--preview") + 1], pixels, bends, dict(tabs))

    def put(name, data):
        with open(os.path.join(out, name), "wb") as f:
            f.write(bytes(data))

    for name, blk in zip(("tiles8000.bin", "tiles9000.bin", "tiles8800.bin"), blocks):
        put(name, b"".join(blk))
    put("map.bin", tilemap)
    put("car.bin", car_tiles() + mouth_tiles()
        + b"".join(pack_object(o) for o in small_car_objects()))
    put("rlane.bin", rival_lane_tables())
    put("dist.bin", dist_to_line())
    put("lane.bin", lane_offsets())
    tabs = tabs + tunnel_pal_tables()
    put("skybgp.bin", with_fades(sky_bgp()))
    put("bend.bin", [v for row in bends for v in row])
    put("shear.bin", [v for row in shear_tables() for v in row])
    for name, data in tabs:
        put("pal_" + name.lower() + ".bin", with_fades(data))

    with open(os.path.join(out, "consts.inc"), "w") as f:
        f.write("; generated by gen_gfx.py\n")
        f.write(f"DEF HORIZON EQU {HORIZON}\nDEF GROUND_LINES EQU {GROUND}\n")
        f.write(f"DEF VISIBLE_D EQU {VISIBLE}\nDEF HUD_LINE EQU {HUD_LINE}\n")
        f.write(f"DEF SKY_STATIC EQU {SKY_STATIC}\nDEF HUD_BGP EQU {HUD_BGP}\n")
        f.write(f"DEF BEND_LEVELS EQU {LEVELS}\nDEF VIEW_X EQU {VIEW_X}\n")
        f.write(f"DEF SPLIT_LINE EQU {split_line}\nDEF CAR_TILE EQU {128 - OBJ_RESERVE}\n")
        f.write(f"DEF SHEAR_MAX EQU {SHEAR_MAX}\nDEF ROAD_HALF EQU {ROAD}\n")
        for name in HUD_ORDER:
            f.write(f"DEF HUD_{name} EQU {hud[name]}\n")
        f.write(f"DEF SPAWN_DIST EQU {SPAWN_DIST}\nDEF CAR_D EQU {CAR_D}\n")
        f.write(f"DEF MOUTH_D2 EQU {MOUTH_FROM[1]}\nDEF MOUTH_D3 EQU {MOUTH_FROM[2]}\n")
        f.write(f"DEF RIVAL_D16 EQU {RIVAL_FROM[0]}\nDEF RIVAL_D12 EQU {RIVAL_FROM[1]}\n")
        f.write(f"DEF RIVAL_D8 EQU {RIVAL_FROM[2]}\nDEF RIVAL_D4 EQU {RIVAL_FROM[3]}\n")
        f.write("MACRO RIVAL_LANE_U\n    db " + ", ".join(map(str, RIVAL_LANES)) + "\nENDM\n")
        # The per-line fill is unrolled: each line's depth is a constant in the code.
        phase = row_phase()
        for macro, table in (("FILL_ALL_BANDS", lambda n, far: n),
                             ("FILL_TUNNEL_BANDS", lambda n, far: "TFar" if far else "T" + n)):
            f.write(f"MACRO {macro}\n")
            for lo, hi, name, coarse in BANDS:
                f.write("    LINK_PUMP\n")
                f.write(f"    FILL_BAND Pal{table(name, coarse)}, {1 if coarse else 0}\n")
                for d in range(lo, min(hi, VISIBLE) + 1):
                    f.write(f"    FILL_LINE {phase[HORIZON + d - 1]}\n")
            f.write("ENDM\n")


def preview(outdir, pixels, bends, tabs):
    """Render what the Game Boy should show, to judge the art without building the ROM."""
    from PIL import Image
    os.makedirs(outdir, exist_ok=True)
    grey = [(224, 248, 208), (136, 192, 112), (52, 104, 86), (8, 24, 32)]
    phase = row_phase()
    skyp = sky_bgp()
    for name, pos, lv in (("a", 0, 0), ("b", 9, 0), ("c", 18, 0), ("left", 300, -32),
                          ("right", 700, 20)):
        img = Image.new("RGB", (160, 144))
        for y in range(144):
            if y < HORIZON:
                pal, scx = skyp[y], 0
            else:
                d = y - HORIZON + 1
                band = next(b for b in BANDS if b[0] <= d <= b[1])
                t = (pos >> 4) if band[3] else pos
                pal = tabs[band[2]][(phase[y] + t) & 255]
                scx = bends[lv + LEVELS][d - 1]
            for x in range(160):
                c = pixels[y][(x + scx) & 255]
                img.putpixel((x, y), grey[(pal >> (c * 2)) & 3])
        img.resize((480, 432), Image.NEAREST).save(os.path.join(outdir, f"pre_{name}.png"))


if __name__ == "__main__":
    main()

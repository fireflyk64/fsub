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

usage: fzero_gfx.py OUTDIR [--preview DIR]
"""
import os
import sys

W = 256                 # tilemap width in pixels
HORIZON = 40            # first ground line; lines 0..39 are sky
GROUND = 104            # ground lines (40..143), d = 1 (horizon) .. 104 (bottom)
CX = 128                # vanishing point, map pixel
DEPTH = 16640.0         # z(d) = DEPTH / d, in world units (1 unit = 1 pixel on the bottom line)
VIEW_X = 48             # SCX when the road is straight: shows map x 48..207
MAX_BEND = 48           # pixels the horizon end of the road can slide either way
LEVELS = 32             # bend steps each side (65 tables)

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
# Sky colour numbers: 0 sky (shade set per line), 1 building, 2 windows, 3 stars / rim light
BUILDINGS = [
    # (width px, height px, style)
    (16, 14, "slab"), (8, 22, "spire"), (24, 10, "dome"), (16, 18, "twin"),
    (8, 12, "slab"), (16, 24, "tower"), (24, 12, "slab"), (8, 16, "spire"),
]


def sky_pixels():
    px = [[0] * W for _ in range(HORIZON)]
    # Stars: three one-pixel patterns reused all over the upper sky (cheap in tiles).
    spots = ((2, 1), (6, 3), (3, 4))
    for i in range(40):
        tx, ty, kind = hash8(i * 13 + 5) % 32, hash8(i * 29 + 1) % 2, i % 3
        ox, oy = spots[kind]
        if not any(px[ty * 8 + r][tx * 8 + c] for r in range(8) for c in range(8)):
            px[ty * 8 + oy][tx * 8 + ox] = 3
    x = 0
    k = 0
    while x < W:
        w, h, style = BUILDINGS[(k * 3 + k // 8) % len(BUILDINGS)]
        k += 1
        if x + w > W:
            w = W - x
        top = HORIZON - h
        for yy in range(top, HORIZON):
            for xx in range(x, x + w - 1):
                lx, ly = xx - x, yy - top
                inside = True
                if style == "spire":
                    inside = ly >= 8 or lx in (3,) or (ly >= 4 and 2 <= lx <= 4)
                elif style == "dome":
                    inside = ly >= 4 or abs(lx - (w - 1) / 2 + 0.5) < 3 + ly * 2.5
                elif style == "twin":
                    inside = ly >= 6 or lx < 5 or lx > w - 7
                elif style == "tower":
                    inside = ly >= 10 or 4 <= lx <= w - 6 or (ly < 3 and lx == w // 2 - 1)
                    if ly < 3:
                        inside = lx == w // 2 - 1
                if not inside:
                    continue
                c = 1
                if lx == 0:
                    c = 3                         # lit left edge
                elif ly > 2 and yy % 3 == 1 and lx % 2 == 0 and (lx + yy // 3) % 6:
                    c = 2                         # window
                px[yy][xx] = c
        x += w
    return px


def sky_bgp():
    """BGP for lines 0..39: the sky colour fades toward a glow at the horizon."""
    out = []
    for y in range(HORIZON):
        if y < 13:
            sky = 3
        elif y < 17:
            sky = 3 if y % 2 else 2               # line dither between bands
        elif y < 24:
            sky = 2
        elif y < 28:
            sky = 2 if y % 2 else 1
        elif y < 35:
            sky = 1
        else:
            sky = 1 if y % 2 and y < 38 else 0
        # buildings black, windows white, rim/star: white on the dark sky, grey lower down
        out.append(bgp(sky, 3, 0, 0 if y < 13 else 2))
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
................
......3333......
.....312213.....
....33222233....
..3.31222213.3..
.33331111113333.
.31331111113313.
.31311111111313.
3313113333113133
3113131111313113
3113132222313113
3333312222133333
.33.33333333.33.
.3..31133113..3.
....32233223....
.....33..33.....
"""


def car_tiles():
    rows = CAR.strip().split("\n")
    assert len(rows) == 16 and all(len(r) == 16 for r in rows)
    out = bytearray()
    for half in (0, 8):
        for y in range(16):
            lo = hi = 0
            for x in range(8):
                c = rows[y][half + x]
                v = 0 if c == "." else int(c)
                lo = (lo << 1) | (v & 1)
                hi = (hi << 1) | (v >> 1)
            out += bytes((lo, hi))
    return bytes(out)


# ----------------------------------------------------------------------------------------
OBJ_RESERVE = 32        # tiles kept free for sprites at the end of the $8000 block


def build():
    """Draw everything, cut it into tiles and spread those over the three VRAM blocks.

    The background can only name 256 tiles at once, but LCDC bit 4 picks which block tile
    numbers 0-127 come from.  Flipping it part way down the screen gives the picture up to
    384 tiles: block $8000 for the upper part, $9000 for the lower part, and $8800
    (numbers 128-255) visible to both.
    """
    sky = sky_pixels()
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
                reach = abs(VIEW_X - bends[0][y - HORIZON])
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

    best = None
    for split in range(5, 17):                    # first tile row drawn from the $9000 block
        top = {t for t in slots[:split * 32] if t}
        bot = {t for t in slots[split * 32:] if t}
        cap_top = 128 - OBJ_RESERVE
        only_top, only_bot = sorted(top - bot), sorted(bot - top)
        shared = sorted(top & bot) + only_top[cap_top:] + only_bot[128:]
        if best is None or len(shared) < len(best[3]):
            best = (split, only_top[:cap_top], only_bot[:128], shared)
    split, blk8000, blk9000, blk8800 = best
    total = len(blk8000) + len(blk9000) + len(blk8800)
    print(f"fzero_gfx: {total} background tiles: {len(blk8000)} upper + {len(blk9000)} lower"
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
    return pixels, (blk8000, blk9000, blk8800), tilemap, bends, split * 8


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    pixels, blocks, tilemap, bends, split_line = build()
    tabs = pal_tables()
    if "--preview" in sys.argv:
        preview(sys.argv[sys.argv.index("--preview") + 1], pixels, bends, dict(tabs))

    def put(name, data):
        with open(os.path.join(out, name), "wb") as f:
            f.write(bytes(data))

    for name, blk in zip(("tiles8000.bin", "tiles9000.bin", "tiles8800.bin"), blocks):
        put(name, b"".join(blk))
    put("map.bin", tilemap)
    put("car.bin", car_tiles())
    put("rowphase.bin", row_phase())
    put("skybgp.bin", sky_bgp())
    put("bend.bin", [v for row in bends for v in row])
    for name, data in tabs:
        put("pal_" + name.lower() + ".bin", data)

    with open(os.path.join(out, "consts.inc"), "w") as f:
        f.write("; generated by fzero_gfx.py\n")
        f.write(f"DEF HORIZON EQU {HORIZON}\nDEF GROUND_LINES EQU {GROUND}\n")
        f.write(f"DEF BEND_LEVELS EQU {LEVELS}\nDEF VIEW_X EQU {VIEW_X}\n")
        f.write(f"DEF SPLIT_LINE EQU {split_line}\nDEF CAR_TILE EQU {128 - OBJ_RESERVE}\n")
        f.write("MACRO FILL_ALL_BANDS\n")
        for lo, hi, name, coarse in BANDS:
            f.write(f"    FILL_BAND Pal{name}, {HORIZON + hi}, {1 if coarse else 0}\n")
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

"""Figures for the fsub blog post, composited from memory dumps of the running ROM.

    ./make.sh            captures (into cap/) and draws everything into img/
    python3 figs.py scx  redraws one figure from the captures already there

The frames each figure uses are named in its function; if the game changes, pick new ones.
Everything in img/ except corner-kink.png was captured from the build at commit 9ca59dc (Oct 9);
corner-kink.png comes from f01cb09, after the tracks were redrawn as straights and corners.
"""
import os
import sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.chdir(HERE)
from gbview import *

OUT = os.path.join(HERE, 'img') + '/'
BG = (20, 22, 26)
INK = (230, 232, 236)
QUIET = (150, 158, 170)
ORANGE = (255, 166, 48)
CYAN = (64, 208, 255)
PINK = (255, 95, 162)
GREEN = (125, 220, 111)
FALSE = np.array([[27, 42, 65], [141, 153, 174], [46, 196, 182], [255, 159, 28]], dtype=np.uint8)   # colour numbers 0..3


def font(size, bold=False, mono=False):
    if mono:
        return ImageFont.truetype('/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf', size)
    return ImageFont.truetype('/usr/share/fonts/opentype/inter/Inter-%s.otf' % ('SemiBold' if bold else 'Regular'), size)


def up(a, pal, scale, blank=BG):
    return to_img(a, pal, scale, blank)


def bg_numbers(d, scroll=True):
    """Colour numbers of the background as each line shows it (no window, no sprites)."""
    cmap = d.bgmap()
    out = np.zeros((144, 160), dtype=np.int32)
    for y in range(144):
        sx = int(d.scx[d.line(y)]) if scroll else 48
        out[y] = cmap[y, (np.arange(160) + sx) & 255]
    return out


def label(dr, xy, s, size=24, fill=INK, bold=False, mono=False, anchor='la'):
    dr.text(xy, s, font=font(size, bold, mono), fill=fill, anchor=anchor)


def frame(im, box, color, width=3):
    ImageDraw.Draw(im).rectangle(box, outline=color, width=width)


def legend(dr, x, y, items, size=20):
    for col, s in items:
        dr.rectangle((x, y + 3, x + 18, y + 21), fill=tuple(col))
        dr.text((x + 26, y), s, font=font(size), fill=QUIET)
        x += 26 + dr.textlength(s, font=font(size)) + 28
    return x


# ----------------------------------------------------------------------------------------
def fig_hero():
    a, b = Dump('cap/t0/f00180'), Dump('cap/t0/f01620')
    im = Image.new('RGB', (640 * 2 + 24, 576), BG)
    im.paste(up(a.fb, GREY, 4), (0, 0))
    im.paste(up(b.fb, GREY, 4), (664, 0))
    im.save(OUT + 'hero.png')


def fig_tilemap():
    d = Dump('cap/prac/p-straight')
    cmap = d.bgmap()[:144]
    S = 3
    W, H = 768 + 40 + 480, 432 + 96
    im = Image.new('RGB', (W, H), BG)
    dr = ImageDraw.Draw(im)
    label(dr, (0, 4), 'In VRAM: one 256 x 144 picture, as colour numbers', 24, INK, True)
    label(dr, (808, 4), 'On screen', 24, INK, True)
    im.paste(up(cmap, FALSE, S), (0, 44))
    frame(im, (48 * S, 44, (48 + 160) * S - 1, 44 + 432 - 1), (255, 255, 255), 3)
    dr.rectangle((48 * S + 3, 44 + 3, 48 * S + 372, 44 + 36), fill=BG)
    label(dr, (48 * S + 12, 44 + 8), 'the 160 pixels a straight road shows', 20, (255, 255, 255))
    im.paste(up(d.fb, GREY, S), (808, 44))
    legend(dr, 0, 44 + 432 + 16, [(FALSE[0], '0  street / void'), (FALSE[1], '1  road'), (FALSE[2], '2  buildings A, bumpers, dashes'), (FALSE[3], '3  buildings B')])
    im.save(OUT + 'tilemap.png')


def bgp_strip(d, scale, cellw, y0=0, y1=144):
    """Per-line palette as four swatches a line (colour numbers 0..3 left to right)."""
    a = np.zeros((y1 - y0, 4), dtype=np.int32)
    for y in range(y0, y1):
        v = int(d.bgp[d.line(y)])
        a[y - y0] = [(v >> (2 * c)) & 3 for c in range(4)]
    im = to_img(a, GREY, 1).resize((4 * cellw, (y1 - y0) * scale), Image.NEAREST)
    return im


def fig_bgp():
    d = Dump('cap/t0/f00500')
    S = 3
    cn = bg_numbers(d)
    cn[HUD_LINE:] = -1
    shaded = d.render(obj=False, win=False)
    shaded[HUD_LINE:] = -1
    sw = 44
    W = 480 + 70 + 4 * sw + 70 + 480
    im = Image.new('RGB', (W, 432 + 60), BG)
    dr = ImageDraw.Draw(im)
    y0 = 52
    label(dr, (0, 6), 'Colour numbers (never change)', 24, INK, True)
    im.paste(up(cn, FALSE, S, BG), (0, y0))
    x = 480
    label(dr, (x + 35, y0 + 216), '×', 44, INK, True, anchor='mm')
    x += 70
    label(dr, (x, 6), 'BGP per line', 24, INK, True)
    im.paste(bgp_strip(d, S, sw, 0, HUD_LINE), (x, y0))
    for c in range(4):
        dr.rectangle((x + c * sw + 4, y0 + 432 - 20, x + c * sw + sw - 5, y0 + 432 - 4), fill=tuple(FALSE[c]))
    x += 4 * sw
    label(dr, (x + 35, y0 + 216), '=', 44, INK, True, anchor='mm')
    x += 70
    label(dr, (x, 6), 'What the LCD shows', 24, INK, True)
    im.paste(up(shaded, GREY, S, BG), (x, y0))
    im.save(OUT + 'bgp-equation.png')


def fig_flow():
    """Space-time picture: the shade of building colours on every ground line, frame after frame."""
    ix = load_index('cap/dense1')[1:]
    n = len(ix)
    cw, S = 12, 4
    a2 = np.zeros((HUD_LINE - HORIZON, n), dtype=np.int32)
    a3 = np.zeros_like(a2)
    speeds = []
    for k, e in enumerate(ix):
        d = Dump('cap/dense1/' + e['name'])
        for y in range(HORIZON, HUD_LINE):
            v = int(d.bgp[y])
            a2[y - HORIZON, k] = (v >> 4) & 3
            a3[y - HORIZON, k] = (v >> 6) & 3
        speeds.append(e['speed'])
    W = 110 + n * cw + 20
    h = (HUD_LINE - HORIZON) * S
    im = Image.new('RGB', (W, h + 110), BG)
    dr = ImageDraw.Draw(im)
    label(dr, (110, 4), 'Shade of colour 2 on each ground line, over the first %d frames of a race' % n, 24, INK, True)
    x0, y0 = 110, 50
    im.paste(to_img(a2, GREY, 1).resize((n * cw, h), Image.NEAREST), (x0, y0))
    label(dr, (x0 - 12, y0 + 6), 'horizon', 20, QUIET, anchor='ra')
    label(dr, (x0 - 12, y0 + 22), 'line 40', 20, QUIET, anchor='ra')
    label(dr, (x0 - 12, y0 + h - 36), 'line 135', 20, QUIET, anchor='ra')
    label(dr, (x0 - 12, y0 + h - 16), 'nearest', 20, QUIET, anchor='ra')
    label(dr, (x0, y0 + h + 12), 'frame 0: standing on the grid', 20, QUIET)
    label(dr, (x0 + n * cw, y0 + h + 12), 'frame %d: %.1f units a frame' % (n - 1, speeds[-1]), 20, QUIET, anchor='ra')
    dr.line((x0, y0 + h + 44, x0 + n * cw, y0 + h + 44), fill=QUIET, width=2)
    dr.polygon([(x0 + n * cw, y0 + h + 44), (x0 + n * cw - 12, y0 + h + 38), (x0 + n * cw - 12, y0 + h + 50)], fill=QUIET)
    im.save(OUT + 'bgp-flow.png')
    return speeds


# ----------------------------------------------------------------------------------------
def map_panel(d, S, upto=144, cur=None, bright=None):
    """The background map (256x144) in false colour: dim, with the part the screen has read so far lit."""
    cmap = d.bgmap()[:144]
    lit = np.zeros((144, 256), dtype=bool)
    for y in range(min(upto, HUD_LINE)):
        sx = int(d.scx[d.line(y)])
        lit[y, (np.arange(160) + sx) & 255] = True
    rgb = FALSE[cmap].astype(np.float32)
    dim = rgb * 0.30 + np.array(BG, dtype=np.float32) * 0.45
    rgb = np.where(lit[:, :, None], rgb, dim).astype(np.uint8)
    im = Image.fromarray(rgb, 'RGB').resize((256 * S, 144 * S), Image.NEAREST)
    dr = ImageDraw.Draw(im)
    # outline of the lit region: its left and right edge on every line
    for y in range(min(upto, HUD_LINE)):
        sx = int(d.scx[d.line(y)])
        for x in (sx & 255, (sx + 159) & 255):
            dr.rectangle((x * S, y * S, x * S + S - 1, y * S + S - 1), fill=(255, 255, 255))
    if cur is not None and cur < HUD_LINE:
        sx = int(d.scx[d.line(cur)])
        for a, b in ([(sx, sx + 159)] if sx + 159 < 256 else [(sx, 255), (0, (sx + 159) & 255)]):
            dr.rectangle((a * S - 2, cur * S - 2, b * S + S + 1, cur * S + S + 1), outline=ORANGE, width=3)
    return im


def scx_plot(d, S, w=170, upto=144, span=96):
    """Signed scroll offset from the straight-road value, plotted against the same lines."""
    im = Image.new('RGB', (w, 144 * S), BG)
    dr = ImageDraw.Draw(im)
    cx = w // 2
    k = (w / 2 - 8) / span
    dr.line((cx, 0, cx, HUD_LINE * S), fill=(70, 76, 86), width=2)
    dr.line((0, HORIZON * S, w, HORIZON * S), fill=(48, 52, 60), width=1)
    pts = []
    for y in range(min(upto, HUD_LINE)):
        off = ((int(d.scx[d.line(y)]) - 48 + 128) & 255) - 128
        x = cx + off * k
        col = ORANGE if y >= HORIZON else QUIET
        dr.rectangle((min(cx, x), y * S, max(cx, x), y * S + S - 1), fill=(90, 66, 34) if y >= HORIZON else (52, 56, 64))
        dr.rectangle((x - 2, y * S, x + 2, y * S + S - 1), fill=col)
    return im


STATES = [('prac/p-straight', 'Straight, car centred', 'every ground line reads from the same column'),
          ('prac/p-bend-right-32', 'Hardest right bend', 'the far lines slide most: a squared curve'),
          ('prac/p-steer-right', 'Straight, car hard right', 'camera shear: a straight slope, near lines slide most'),
          ('prac/p-bend-left-steer-right', 'Left bend while steering right', 'the two tables simply add')]


def fig_scx():
    S = 2
    rowh = 288 + 78
    W = 512 + 20 + 170 + 20 + 320
    im = Image.new('RGB', (W, rowh * len(STATES) - 8), BG)
    dr = ImageDraw.Draw(im)
    for k, (name, title, sub) in enumerate(STATES):
        d = Dump('cap/' + name)
        y = k * rowh
        label(dr, (0, y + 2), title, 24, INK, True)
        offs = [((int(d.scx[yy]) - 48 + 128) & 255) - 128 for yy in range(HORIZON, HUD_LINE)]
        label(dr, (0, y + 32), sub, 20, QUIET)
        label(dr, (532 + 85, y + 32), '%+d to %+d px' % (offs[0], offs[-1]), 20, ORANGE, anchor='ma')
        label(dr, (722, y + 32), 'screen', 20, QUIET)
        im.paste(map_panel(d, S), (0, y + 64))
        im.paste(scx_plot(d, S), (532, y + 64))
        im.paste(up(d.fb, GREY, S), (722, y + 64))
    im.save(OUT + 'scx-states.png')


SCAN = 'cap/t0/f01620'


def scan_frame(d, upto, S=2, note=''):
    W = 512 + 20 + 320
    im = Image.new('RGB', (W, 288 + 44), BG)
    dr = ImageDraw.Draw(im)
    cur = upto - 1
    im.paste(map_panel(d, S, upto, cur), (0, 44))
    part = d.render(upto=upto)
    im.paste(up(part, GREY, S, (34, 37, 43)), (532, 44))
    if upto < 144:
        dr.rectangle((532, 44 + upto * S, 532 + 319, 44 + upto * S + 2), fill=ORANGE)
    if upto > HUD_LINE:          # the window: a second map, pinned at x = 0, drawn over the last eight lines
        wim = up(d.render(bg=False, obj=False)[HUD_LINE:upto], GREY, S, BG)
        im.paste(wim, (0, 44 + HUD_LINE * S))
        dr.rectangle((0, 44 + HUD_LINE * S - 2, 320 + 1, 44 + upto * S + 1), outline=PINK, width=3)
    sx = int(d.scx[d.line(cur)])
    label(dr, (0, 6), 'LY %3d' % cur, 26, INK, True, mono=True)
    label(dr, (130, 6), ('SCX %3d' % sx) if cur < HUD_LINE else 'window', 26, ORANGE if cur < HUD_LINE else PINK, True, mono=True)
    label(dr, (290, 10), note, 20, QUIET)
    return im


def fig_scan():
    d = Dump(SCAN)
    steps = [(32, 'sky: one SCX for every line so far, no interrupt yet'), (64, 'ground: each line now gets its own SCX'), (104, ''),
             (144, 'a second map, pinned at x = 0, over the last 8 lines')]
    frames = [scan_frame(d, u, note=n) for u, n in steps]
    W, h = frames[0].size
    im = Image.new('RGB', (W, (h + 22) * len(frames) - 22), BG)
    for k, f in enumerate(frames):
        im.paste(f, (0, k * (h + 22)))
    im.save(OUT + 'scan-steps.png')
    # the same thing moving
    seq = [scan_frame(d, u) for u in range(2, 145, 2)]
    seq = [seq[-1]] * 12 + seq + [seq[-1]] * 20
    seq[0].save(OUT + 'scan.gif', save_all=True, append_images=seq[1:], duration=60, loop=0, optimize=True)


def tag(dr, xy, s, col, size=20):
    w = dr.textlength(s, font=font(size))
    dr.rectangle((xy[0] - 6, xy[1] - 3, xy[0] + w + 6, xy[1] + size + 7), fill=BG)
    dr.text(xy, s, font=font(size), fill=col)


def fig_window():
    d = Dump('cap/t0/f01620')
    S = 3
    panels = [('Background layer', d.render(win=False, obj=False, under=True)), ('Window layer', d.render(bg=False, obj=False)),
              ('Sprites', d.render(bg=False, win=False)), ('What the LCD shows', d.fb)]
    W = 480 * 2 + 24
    im = Image.new('RGB', (W, (432 + 44) * 2 + 16), BG)
    dr = ImageDraw.Draw(im)
    for k, (t, a) in enumerate(panels):
        x, y = (k % 2) * 504, (k // 2) * (432 + 60)
        label(dr, (x, y + 4), t, 24, INK, True)
        im.paste(up(a, GREY, S, (34, 37, 43)), (x, y + 44))
        if k == 0:
            dr.rectangle((x, y + 44 + HUD_LINE * S - 3, x + 479, y + 44 + 431), outline=PINK, width=3)
            tag(dr, (x + 10, y + 44 + HUD_LINE * S - 40), 'lines 136-143: blank tiles, never seen', PINK)
        if k == 1:
            dr.rectangle((x, y + 44 + HUD_LINE * S - 3, x + 479, y + 44 + 431), outline=PINK, width=3)
            tag(dr, (x + 10, y + 44 + HUD_LINE * S - 40), 'WY = 136, WX = 7: its own map, no scroll', PINK)
    im.save(OUT + 'window-layers.png')


def fig_sky():
    """The skyline is the top of the same layer: its lines share one SCX, the heading."""
    ix = load_index('cap/dense3')[1:]
    picks = [ix[20], ix[120], ix[230]]
    S = 2
    rowh = 288 + 56
    W = 512 + 20 + 320
    im = Image.new('RGB', (W, rowh * len(picks) - 12), BG)
    dr = ImageDraw.Draw(im)
    for k, e in enumerate(picks):
        d = Dump('cap/dense3/' + e['name'])
        y = k * rowh
        sky = int(d.scx[0])
        label(dr, (0, y + 6), 'sky lines 0-39', 22, CYAN, True)
        label(dr, (170, y + 6), 'SCX %3d' % sky, 22, CYAN, True, mono=True)
        label(dr, (330, y + 8), 'ground lines 40-135: SCX from the bend', 20, QUIET)
        mp = map_panel(d, S)
        md = ImageDraw.Draw(mp)
        for a, b in ([(sky, sky + 159)] if sky + 159 < 256 else [(sky, 255), (0, (sky + 159) & 255)]):
            md.rectangle((a * S, 0, b * S + S - 1, HORIZON * S - 1), outline=CYAN, width=3)
        im.paste(mp, (0, y + 44))
        scr = up(d.fb, GREY, S)
        ImageDraw.Draw(scr).rectangle((0, 0, 319, HORIZON * S - 1), outline=CYAN, width=3)
        im.paste(scr, (532, y + 44))
    im.save(OUT + 'sky-heading.png')
    return [(e['race'], e['bend'], e['speed'], int(Dump('cap/dense3/' + e['name']).scx[0])) for e in picks]


def sprite_numbers(d, y0, y1, x0, x1):
    """Colour numbers of the sprite layer (0 = nothing), and whether each pixel uses OBP1."""
    cn = np.zeros((144, 160), dtype=np.int32)
    p1 = np.zeros((144, 160), dtype=bool)
    for y in range(144):
        c = []
        for k in range(40):
            oy, ox, t, at = (d.rd(0xFE00 + k * 4 + j) for j in range(4))
            if 0 <= y - (oy - 16) < 16:
                c.append((ox, k, oy, t, at))
        for ox, k, oy, t, at in sorted(c[:10], key=lambda q: (-q[0], -q[1])):
            r = y - (oy - 16)
            row = d.tiles[(t & 0xFE) + (r >> 3)][r & 7]
            if at & 0x20:
                row = row[::-1]
            for px in range(8):
                sx = ox - 8 + px
                if 0 <= sx < 160 and row[px]:
                    cn[y, sx] = row[px]
                    p1[y, sx] = bool(at & 0x10)
    return cn[y0:y1, x0:x1], p1[y0:y1, x0:x1]


def fig_liveries():
    d = Dump('cap/t0/f00180')
    S = 5
    x0, x1, y0, y1 = 40, 124, 58, 136
    cn, p1 = sprite_numbers(d, y0, y1, x0, x1)
    w, h = (x1 - x0) * S, (y1 - y0) * S
    sw = 40
    W = w + 60 + 3 * sw + 60 + w
    im = Image.new('RGB', (W, h + 56 + 290), BG)
    dr = ImageDraw.Draw(im)
    label(dr, (0, 6), 'Sprite pixels: one car, drawn 8 times', 24, INK, True)
    a = np.where(cn > 0, cn, -1)
    im.paste(up(a, FALSE, S, (34, 37, 43)), (0, 52))
    x = w
    label(dr, (x + 30, 52 + h // 2), '×', 44, INK, True, anchor='mm')
    x += 60
    label(dr, (x, 6), 'OBP1 per line', 24, INK, True)
    strip = np.zeros((y1 - y0, 3), dtype=np.int32)
    for y in range(y0, y1):
        v = int(d.obp1[d.line(y)])
        strip[y - y0] = [(v >> (2 * c)) & 3 for c in (1, 2, 3)]
    im.paste(to_img(strip, GREY, 1).resize((3 * sw, h), Image.NEAREST), (x, 52))
    for c in range(3):
        dr.rectangle((x + c * sw + 4, 52 + h + 6, x + c * sw + sw - 5, 52 + h + 20), fill=tuple(FALSE[c + 1]))
    x += 3 * sw
    label(dr, (x + 30, 52 + h // 2), '=', 44, INK, True, anchor='mm')
    x += 60
    label(dr, (x, 6), 'Seven liveries on screen', 24, INK, True)
    im.paste(up(d.fb[y0:y1, x0:x1], GREY, S), (x, 52))
    # the art itself
    yb = 52 + h + 50
    label(dr, (0, yb), 'All the car art in the ROM', 24, INK, True)
    T = 98
    def obj(t):                        # an 8x16 object: two tiles
        return np.vstack([d.tiles[t], d.tiles[t + 1]])
    Z = 9
    xx = 0
    half = obj(T)
    im.paste(up(np.where(half > 0, half, -1), FALSE, Z, (34, 37, 43)), (xx, yb + 44))
    label(dr, (xx, yb + 44 + 16 * Z + 6), 'stored: left half', 18, QUIET)
    xx += 8 * Z + 150
    whole = np.hstack([half, half[:, ::-1]])
    im.paste(up(np.where(whole > 0, whole, -1), FALSE, Z, (34, 37, 43)), (xx, yb + 44))
    label(dr, (xx, yb + 44 + 16 * Z + 6), 'drawn: half + mirror', 18, QUIET)
    xx += 16 * Z + 80
    for t, n, lab in ((T + 18, 12, '12 px'), (T + 20, 8, '8 px'), (T + 22, 4, '4 px')):
        o = obj(t)
        pic = np.hstack([o, o[:, ::-1]]) if n > 8 else o
        im.paste(up(np.where(pic > 0, pic, -1), FALSE, Z, (34, 37, 43)), (xx, yb + 44))
        label(dr, (xx, yb + 44 + 16 * Z + 6), lab, 18, QUIET)
        xx += pic.shape[1] * Z + 40
    im.save(OUT + 'liveries.png')


BLOCK_TINT = np.array([[64, 208, 255], [255, 95, 162], [255, 166, 48]], dtype=np.float32)    # $8000, $8800, $9000


def fig_blocks():
    d = Dump('cap/prac/p-straight')
    S = 4
    shade = d.render(obj=False)
    blk = np.zeros((144, 160), dtype=np.int32)
    for y in range(144):
        lower = y >= SPLIT_LINE
        if y < HUD_LINE:
            xs = (np.arange(160) + int(d.scx[d.line(y)])) & 255
            ns = np.array([d.rd(0x9800 + (y // 8) * 32 + (x // 8)) for x in xs])
        else:
            ns = np.array([d.rd(0x9C00 + (x // 8)) for x in range(160)])
        blk[y] = np.where(ns >= 128, 1, 2 if lower else 0)
    rgb = GREY[shade].astype(np.float32) * 0.45 + BLOCK_TINT[blk] * 0.55
    scr = Image.fromarray(rgb.astype(np.uint8), 'RGB').resize((160 * S, 144 * S), Image.NEAREST)
    sd = ImageDraw.Draw(scr)
    sd.rectangle((0, SPLIT_LINE * S - 2, 160 * S - 1, SPLIT_LINE * S + 1), fill=(255, 255, 255))
    Z = 3
    sx = 160 * S + 40
    W = sx + 128 * Z
    im = Image.new('RGB', (W, 44 + 3 * (64 * Z + 40) - 6), BG)
    dr = ImageDraw.Draw(im)
    label(dr, (0, 6), 'Which tile block each pixel came from', 24, INK, True)
    im.paste(scr, (0, 44))
    tag(dr, (10, 44 + SPLIT_LINE * S - 38), 'line 64: LCDC bit 4 flips here', (255, 255, 255))
    names = [('$8000  tiles 0-127, above line 64', 0), ('$8800  tiles 128-255, both halves', 128), ('$9000  tiles 0-127, below line 64', 256)]
    for k, (t, base) in enumerate(names):
        y = 6 + k * (64 * Z + 40)
        sheet = np.zeros((64, 128), dtype=np.int32)
        for i in range(128):
            sheet[(i // 16) * 8:(i // 16) * 8 + 8, (i % 16) * 8:(i % 16) * 8 + 8] = d.tiles[base + i]
        rgbs = GREY[sheet].astype(np.float32) * 0.6 + BLOCK_TINT[k] * 0.4
        im.paste(Image.fromarray(rgbs.astype(np.uint8), 'RGB').resize((128 * Z, 64 * Z), Image.NEAREST), (sx, y + 32))
        label(dr, (sx, y + 2), t, 20, tuple(int(v) for v in BLOCK_TINT[k]))
    im.save(OUT + 'tile-blocks.png')


def strip(names, labels, fn, S=2, cols=4):
    rows = (len(names) + cols - 1) // cols
    W = cols * 160 * S + (cols - 1) * 16
    im = Image.new('RGB', (W, rows * (144 * S + 40) - 4), BG)
    dr = ImageDraw.Draw(im)
    for k, (n, l) in enumerate(zip(names, labels)):
        x, y = (k % cols) * (160 * S + 16), (k // cols) * (144 * S + 40)
        im.paste(up(Dump('cap/' + n).fb, GREY, S), (x, y))
        label(dr, (x, y + 144 * S + 6), l, 20, QUIET)
    im.save(OUT + fn)


def fig_scenery():
    strip(['t0/f00500', 't0/f00900', 't1/f00800', 't2/f00480'], ['City', 'Underpass / tunnel', 'Water', 'Wheat fields'], 'scenery.png')


def fig_gallery():
    strip(['prac/menu', 't0/f00580', 't0/f04460', 't0/f01440', 't1/f00160', 't2/f00160', 't3/f00160', 'mash/f04090'],
          ['Menu', 'Dash plate and tunnel mouth', 'Boost: the sky flashes', 'Off a jump plate',
           'Blue Deep', 'Gold Wind', 'Old Port', 'Wrecked'], 'gallery.png')


def fig_boom():
    ix = [e for e in load_index('cap/mash')[1:] if e['st'] == 2][:7]
    Z = 8
    n = len(ix)
    d0 = Dump('cap/mash/' + ix[0]['name'])
    cx, cy = d0.rd(0xFE01) - 8, d0.rd(0xFE00) - 16      # the car's first sprite
    x0 = max(0, min(160 - 28, cx - 6)); y0 = max(0, min(144 - 24, cy - 6))
    W = n * (28 * Z + 12) - 12
    im = Image.new('RGB', (W, 24 * Z + 34), BG)
    dr = ImageDraw.Draw(im)
    for k, e in enumerate(ix):
        d = Dump('cap/mash/' + e['name'])
        im.paste(up(d.fb[y0:y0 + 24, x0:x0 + 28], GREY, Z), (k * (28 * Z + 12), 0))
        label(dr, (k * (28 * Z + 12), 24 * Z + 6), 'frame %d' % e['boom'], 18, QUIET)
    im.save(OUT + 'explosion.png')


def fig_play():
    ix = load_index('cap/dense3')[1:]
    seq = [up(Dump('cap/dense3/' + e['name']).fb, GREY, 2) for e in ix[::2]]
    seq[0].save(OUT + 'play.gif', save_all=True, append_images=seq[1:], duration=33, loop=0, optimize=True)
    return len(seq)


def fig_kink():
    """A corner on its way: lines beyond where it starts are drawn with its bend and joined on.
    (Captured from the build after the tracks were redrawn as straights and corners.)"""
    picks = ['f00520', 'f00528', 'f00536']
    S = 2
    rowh = 288 + 78
    W = 512 + 20 + 170 + 20 + 320
    im = Image.new('RGB', (W, rowh * len(picks) - 8), BG)
    dr = ImageDraw.Draw(im)
    for k, name in enumerate(picks):
        d = Dump('cap/kink/' + name)
        far = d.rd(SYM['hFarLines'])
        edge = HORIZON + far                       # first line drawn with the bend the car is in
        y = k * rowh
        label(dr, (0, y + 2), 'Corner starts on line %d' % edge, 24, INK, True)
        label(dr, (0, y + 32), 'above it: the corner\'s bend, shifted to join on', 20, QUIET)
        offs = [((int(d.scx[yy]) - 48 + 128) & 255) - 128 for yy in range(HORIZON, HUD_LINE)]
        label(dr, (532 + 85, y + 32), '%+d to %+d px' % (offs[0], offs[-1]), 20, ORANGE, anchor='ma')
        label(dr, (722, y + 32), 'screen', 20, QUIET)
        mp = map_panel(d, S)
        sc = up(d.fb, GREY, S)
        pl = scx_plot(d, S)
        for panel, w in ((mp, 512), (sc, 320), (pl, 170)):
            pd = ImageDraw.Draw(panel)
            for x in range(0, w, 12):
                pd.line((x, edge * S, x + 6, edge * S), fill=CYAN, width=2)
        im.paste(mp, (0, y + 64))
        im.paste(pl, (532, y + 64))
        im.paste(sc, (722, y + 64))
    im.save(OUT + 'corner-kink.png')


ALL = ['hero', 'tilemap', 'bgp', 'flow', 'scx', 'scan', 'sky', 'window', 'liveries', 'blocks', 'scenery', 'gallery', 'boom', 'play', 'kink']

if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    for w in sys.argv[1:] or ALL:
        globals()['fig_' + w]()
        print('fig', w)

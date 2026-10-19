"""A small model of the Game Boy picture, rebuilt from a memory dump: the background with the
per-line registers the game keeps in its line buffers, the window, and the sprites."""
import json, os, re
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYM = {}
for l in open(ROOT + '/fzero.sym'):
    m = re.match(r'^[0-9a-f]{2}:([0-9a-f]{4}) (\w+)$', l.strip(), re.I)
    if m:
        SYM[m.group(2)] = int(m.group(1), 16)

GREY = np.array([[255, 255, 255], [170, 170, 170], [85, 85, 85], [0, 0, 0]], dtype=np.uint8)
HORIZON, HUD_LINE, SKY_STATIC, SPLIT_LINE = 40, 136, 32, 64


class Dump:
    def __init__(self, path):
        self.mem = np.frombuffer(open(path + '.mem', 'rb').read(), dtype=np.uint8).astype(np.int32)
        fb = np.frombuffer(open(path + '.rgba', 'rb').read(), dtype=np.uint8).reshape(144, 160, 4)
        self.fb = (3 - (fb[:, :, 0].astype(np.int32) + 42) // 85)      # shade index 0 white .. 3 black
        self.front = self.rd(SYM['hFront'])
        base = (self.front << 8) - 0x8000
        self.bgp = self.mem[base:base + 256]
        self.scx = self.mem[base + 256:base + 512]
        self.obp1 = self.mem[base + 512:base + 768]
        t = self.mem[0:0x1800].reshape(384, 8, 2)
        bits = 7 - np.arange(8)
        lo = (t[:, :, 0:1] >> bits) & 1
        hi = (t[:, :, 1:2] >> bits) & 1
        self.tiles = lo | (hi << 1)                                     # (384, 8, 8) colour numbers

    def rd(self, a):
        return int(self.mem[a - 0x8000])

    def line(self, y):
        """Which buffer entry a screen line is drawn with: the sky's top lines never get an interrupt."""
        return 0 if y < SKY_STATIC else y

    def tile(self, n, lower):
        return self.tiles[256 + n] if (lower and n < 128) else self.tiles[n]

    def bgmap(self, base=0x9800, split=True):
        """The 256x256 background as colour numbers.  Tile rows 8+ are drawn after the tile block switch."""
        out = np.zeros((256, 256), dtype=np.int32)
        for ty in range(32):
            for tx in range(32):
                n = self.rd(base + ty * 32 + tx)
                out[ty * 8:ty * 8 + 8, tx * 8:tx * 8 + 8] = self.tile(n, split and ty >= 8)
        return out

    def render(self, bg=True, win=True, obj=True, scroll=True, palette=True, upto=144, under=False):
        """-> (144,160) shade indexes; -1 where nothing was drawn."""
        out = np.full((144, 160), -1, dtype=np.int32)
        cmap = self.bgmap()
        wmap = self.bgmap(0x9C00, split=False)
        wtiles = np.zeros((8, 160), dtype=np.int32)
        for tx in range(20):
            wtiles[:, tx * 8:tx * 8 + 8] = self.tile(self.rd(0x9C00 + tx), True)
        obp0 = self.rd(0xFF48)
        for y in range(min(upto, 144)):
            i = self.line(y)
            bgp = int(self.bgp[i]) if palette else 0xE4
            cn = np.zeros(160, dtype=np.int32)
            drawn = False
            if bg and (y < HUD_LINE or under):
                xs = (np.arange(160) + (int(self.scx[i]) if scroll else 48)) & 255
                cn = cmap[y, xs]
                drawn = True
            if win and y >= HUD_LINE:
                cn = wtiles[y - HUD_LINE]
                drawn = True
            if drawn:
                out[y] = (bgp >> (2 * cn)) & 3
            if obj:
                cands = []
                for k in range(40):
                    oy, ox, t, at = (self.rd(0xFE00 + k * 4 + j) for j in range(4))
                    if 0 <= y - (oy - 16) < 16:
                        cands.append((ox, k, oy, t, at))
                cands = cands[:10]
                for ox, k, oy, t, at in sorted(cands, key=lambda c: (-c[0], -c[1])):
                    r = y - (oy - 16)
                    if at & 0x40:
                        r = 15 - r
                    row = self.tiles[(t & 0xFE) + (r >> 3)][r & 7]
                    if at & 0x20:
                        row = row[::-1]
                    pal = int(self.obp1[i]) if at & 0x10 else obp0
                    for px in range(8):
                        sx = ox - 8 + px
                        if 0 <= sx < 160 and row[px]:
                            out[y, sx] = (pal >> (2 * int(row[px]))) & 3
        return out


def to_img(shades, pal=GREY, scale=1, blank=(40, 44, 52)):
    a = np.zeros(shades.shape + (3,), dtype=np.uint8)
    a[:] = blank
    m = shades >= 0
    a[m] = pal[shades[m]]
    im = Image.fromarray(a, 'RGB')
    if scale != 1:
        im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    return im


def load_index(d):
    return json.load(open(d + '/index.json'))

#!/usr/bin/env python3
"""Read and write hUGETracker .uge songs, and export one as RGBDS assembly for hUGEDriver.

The export follows hUGETracker's own "Export RGBDS .asm" (src/codegen.pas), so a song
edited in the tracker builds straight into the ROM.

usage: uge.py SONG.uge OUT.asm --name LABEL [--bank N]
"""
import struct
import sys

NO_NOTE = 90
NOTE_NAMES = [n + str(o) for o in range(3, 9)
              for n in ("C_", "C#", "D_", "D#", "E_", "F_", "F#", "G_", "G#", "A_", "A#", "B_")]


class Reader:
    def __init__(self, data):
        self.d, self.p = data, 0

    def u8(self):
        self.p += 1
        return self.d[self.p - 1]

    def u32(self):
        self.p += 4
        return struct.unpack_from("<I", self.d, self.p - 4)[0]

    def shortstring(self):
        raw = self.d[self.p:self.p + 256]
        self.p += 256
        return raw[1:1 + raw[0]].decode("latin-1")

    def string(self):
        n = self.u32()
        s = self.d[self.p:self.p + n].decode("latin-1")
        self.p += n                               # (no terminator, despite the spec)
        return s


class Writer:
    def __init__(self):
        self.b = bytearray()

    def u8(self, v):
        self.b.append(v & 255)

    def u32(self, v):
        self.b += struct.pack("<I", v)

    def shortstring(self, s):
        raw = s.encode("latin-1")[:255]
        self.b += bytes([len(raw)]) + raw + bytes(255 - len(raw))

    def string(self, s):
        raw = s.encode("latin-1")
        self.u32(len(raw))
        self.b += raw


def blank_cell():
    return {"note": NO_NOTE, "instrument": 0, "jump": 0, "effect": 0, "param": 0}


def blank_instrument(kind):
    return {"type": kind, "name": "", "length": 0, "length_enabled": False,
            "volume": 0, "vol_dir": 1, "vol_change": 0,
            "sweep_time": 0, "sweep_dir": 1, "sweep_shift": 0, "duty": 2,
            "wave_volume": 1, "wave": 0, "noise_7bit": 0,
            "sub_enabled": False, "subpattern": [blank_cell() for _ in range(64)]}


def blank_song():
    return {"version": 6, "name": "", "artist": "", "comment": "",
            "duty": [blank_instrument(0) for _ in range(15)],
            "wave": [blank_instrument(1) for _ in range(15)],
            "noise": [blank_instrument(2) for _ in range(15)],
            "waves": [[0] * 32 for _ in range(16)],
            "tempo": 6, "timer_enabled": False, "timer_divider": 0,
            "patterns": {},                       # index -> 64 cells
            "orders": [[], [], [], []],
            "routines": [""] * 16}


# Instrument record: (field, kind) in file order.  The same 12 slots hold different things
# for each instrument type; unused ones are kept so a file survives a round trip.
INSTRUMENT_FIELDS = [("length", "u32"), ("length_enabled", "bool"), ("volume", "u8"),
                     ("vol_dir", "u32"), ("vol_change", "u8"), ("sweep_time", "u32"),
                     ("sweep_dir", "u32"), ("sweep_shift", "u32"), ("duty", "u8"),
                     ("wave_volume", "u32"), ("wave", "u32"), ("noise_7bit", "u32")]


def read(data):
    r = Reader(data)
    s = blank_song()
    s["version"] = r.u32()
    if s["version"] != 6:
        raise SystemExit(f"only .uge version 6 is supported (this is {s['version']}); "
                         "open and re-save it in a current hUGETracker")
    s["name"], s["artist"], s["comment"] = r.shortstring(), r.shortstring(), r.shortstring()
    for bank in ("duty", "wave", "noise"):
        for i in range(15):
            ins = s[bank][i]
            ins["type"] = r.u32()
            ins["name"] = r.shortstring()
            for field, kind in INSTRUMENT_FIELDS:
                ins[field] = r.u32() if kind == "u32" else (bool(r.u8()) if kind == "bool" else r.u8())
            ins["sub_enabled"] = bool(r.u8())
            for cell in ins["subpattern"]:
                cell["note"], cell["instrument"], cell["jump"] = r.u32(), r.u32(), r.u32()
                cell["effect"], cell["param"] = r.u32(), r.u8()
    s["waves"] = [[r.u8() for _ in range(32)] for _ in range(16)]
    s["tempo"] = r.u32()
    s["timer_enabled"] = bool(r.u8())
    s["timer_divider"] = r.u32()
    for _ in range(r.u32()):
        idx = r.u32()
        cells = []
        for _ in range(64):
            c = blank_cell()
            c["note"], c["instrument"], c["jump"] = r.u32(), r.u32(), r.u32()
            c["effect"], c["param"] = r.u32(), r.u8()
            cells.append(c)
        s["patterns"][idx] = cells
    for ch in range(4):
        n = r.u32() - 1                           # stored length is one too many
        s["orders"][ch] = [r.u32() for _ in range(n)]
        r.u32()
    s["routines"] = [r.string() for _ in range(16)]
    s["_trailing"] = data[r.p:]
    return s


def write(s):
    w = Writer()
    w.u32(6)
    w.shortstring(s["name"])
    w.shortstring(s["artist"])
    w.shortstring(s["comment"])
    for bank in ("duty", "wave", "noise"):
        for ins in s[bank]:
            w.u32(ins["type"])
            w.shortstring(ins["name"])
            for field, kind in INSTRUMENT_FIELDS:
                (w.u32 if kind == "u32" else w.u8)(int(ins[field]))
            w.u8(int(ins["sub_enabled"]))
            for c in ins["subpattern"]:
                w.u32(c["note"]), w.u32(c["instrument"]), w.u32(c["jump"])
                w.u32(c["effect"]), w.u8(c["param"])
    for wave in s["waves"]:
        for v in wave:
            w.u8(v)
    w.u32(s["tempo"])
    w.u8(int(s["timer_enabled"]))
    w.u32(s["timer_divider"])
    w.u32(len(s["patterns"]))
    for idx, cells in s["patterns"].items():
        w.u32(idx)
        for c in cells:
            w.u32(c["note"]), w.u32(c["instrument"]), w.u32(c["jump"])
            w.u32(c["effect"]), w.u8(c["param"])
    for order in s["orders"]:
        w.u32(len(order) + 1)
        for o in order:
            w.u32(o)
        w.u32(0)
    for routine in s["routines"]:
        w.string(routine)
    return bytes(w.b) + s.get("_trailing", b"")


# ----------------------------------------------------------------------------------------
def dn(note, mid, effect, param, numeric_note=False):
    if note == NO_NOTE or not 0 <= note < len(NOTE_NAMES):
        n = "___"
    else:
        n = str(note) if numeric_note else NOTE_NAMES[note]
    return f" dn {n},{mid},${(effect << 8 | param) & 0xFFF:03X}"


def to_asm(s, label, bank=None):
    used = sorted({p for order in s["orders"] for p in order})
    highest = {"duty": 0, "wave": 0, "noise": 0}
    top_wave = 0
    for ch, order in enumerate(s["orders"]):
        kind = ("duty", "duty", "wave", "noise")[ch]
        for p in order:
            for c in s["patterns"][p]:
                if c["effect"] == 9 and ch == 2:
                    top_wave = max(top_wave, c["param"])
                if 1 <= c["instrument"] <= 15:
                    highest[kind] = max(highest[kind], c["instrument"])
                    if ch == 2:
                        top_wave = max(top_wave, s["wave"][c["instrument"] - 1]["wave"])
    for ins in s["wave"]:
        if ins["sub_enabled"]:
            top_wave = max([top_wave] + [c["param"] for c in ins["subpattern"] if c["effect"] == 9])

    out = ['include "hUGE.inc"', ""]
    where = f', BANK[{bank}]' if bank is not None else ""
    out += [f'SECTION "{label} Song Data", ROMX{where}', "", f"{label}::", f"db {s['tempo']}",
            "dw order_cnt", "dw order1, order2, order3, order4",
            "dw duty_instruments, wave_instruments, noise_instruments", "dw routines",
            "dw waves", ""]
    out.append(f"order_cnt: db {max(len(o) for o in s['orders']) * 2}")
    for ch, order in enumerate(s["orders"]):
        out.append(f"order{ch + 1}: dw " + ",".join(f"P{p}" for p in order))
    out.append("")
    for p in used:
        out.append(f"P{p}:")
        out += [dn(c["note"], c["instrument"] if 0 <= c["instrument"] <= 15 else 0,
                   c["effect"], c["param"]) for c in s["patterns"][p]]
        out.append("")

    prefix = {"duty": "itSquare", "wave": "itWave", "noise": "itNoise"}
    for kind in ("duty", "wave", "noise"):
        for i in range(highest[kind]):
            ins = s[kind][i]
            if ins["sub_enabled"]:
                out.append(f"{prefix[kind]}SP{i + 1}:")
                for r, c in enumerate(ins["subpattern"][:32]):
                    jump = 1 if r == 31 and c["jump"] == 0 else min(max(c["jump"], 0), 32)
                    out.append(dn(c["note"], jump, c["effect"], c["param"], numeric_note=True))
                out.append("")

    for kind in ("duty", "wave", "noise"):
        out.append(f"{kind}_instruments:")
        for i in range(highest[kind]):
            ins = s[kind][i]
            sub = f"{prefix[kind]}SP{i + 1}" if ins["sub_enabled"] else "0"
            trigger = 0x80 | (0x40 if ins["length_enabled"] else 0)
            envelope = (ins["volume"] << 4) | (8 if ins["vol_dir"] == 0 else 0) | ins["vol_change"]
            out.append(f"{prefix[kind]}inst{i + 1}:")
            if kind == "duty":
                sweep = (ins["sweep_time"] << 4) | (8 if ins["sweep_dir"] == 1 else 0) | ins["sweep_shift"]
                out += [f"db {sweep}", f"db {(ins['duty'] << 6) | (ins['length'] & 63)}",
                        f"db {envelope}", f"dw {sub}", f"db {trigger}"]
            elif kind == "wave":
                out += [f"db {ins['length'] & 255}", f"db {(ins['wave_volume'] & 3) << 5}",
                        f"db {ins['wave']}", f"dw {sub}", f"db {trigger}"]
            else:
                mask = (ins["length"] & 63) | (0x40 if ins["length_enabled"] else 0) \
                    | (0x80 if ins["noise_7bit"] else 0)
                out += [f"db {envelope}", f"dw {sub}", f"db {mask}", "ds 2"]
            out.append("")
    out.append("routines:")
    for i, code in enumerate(s["routines"]):
        out += [f"__hUGE_Routine_{i}:", code, f"__end_hUGE_Routine_{i}:", "ret", ""]
    out.append("waves:")
    for i in range(top_wave + 1):
        wv = s["waves"][i]
        out.append(f"wave{i}: db " + ",".join(str((wv[j] << 4) | wv[j + 1]) for j in range(0, 32, 2)))
    return "\n".join(out) + "\n"


def main():
    args = sys.argv[1:]
    name = args[args.index("--name") + 1]
    bank = int(args[args.index("--bank") + 1]) if "--bank" in args else None
    with open(args[0], "rb") as f:
        song = read(f.read())
    with open(args[1], "w") as f:
        f.write(to_asm(song, name, bank))


if __name__ == "__main__":
    main()

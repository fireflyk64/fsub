#!/usr/bin/env python3
"""Compose the first draft of the race theme and save it as a hUGETracker song.

This only seeds music/race.uge.  From then on the .uge is the song: open it in
hUGETracker, edit, save, rebuild.  Running this again overwrites those edits.

Four channels, 16th-note rows, 4 bars per pattern:
  ch1 lead melody   ch2 chord arpeggios   ch3 wave bass (galloping octaves)   ch4 drums

usage: compose_race.py OUT.uge
"""
import sys

import uge

TEMPO = 5                # ticks per row: 16th notes at 180 beats per minute
ROWS = 64

NAMES = ["C_", "C#", "D_", "D#", "E_", "F_", "F#", "G_", "G#", "A_", "A#", "B_"]


def note(name):
    """'A5' / 'F#4' -> hUGE note name like A_5 / F#4."""
    return (name[0] + "_" + name[1]) if len(name) == 2 else name


def semis(name):
    n = note(name)
    return NAMES.index(n[:2]) + 12 * (int(n[2]) - 3)


def unsemis(v):
    return NAMES[v % 12] + str(v // 12 + 3)


CHORDS = {  # root (bass octave), chord tones for the arpeggio
    "Am": ("A3", ["A4", "C5", "E5", "A5"]),
    "F":  ("F3", ["F4", "A4", "C5", "F5"]),
    "G":  ("G3", ["G4", "B4", "D5", "G5"]),
    "Em": ("E3", ["E4", "G4", "B4", "E5"]),
    "C":  ("C3", ["G4", "C5", "E5", "G5"]),
    "Dm": ("D3", ["F4", "A4", "D5", "F5"]),
    "E":  ("E3", ["E4", "G#4", "B4", "E5"]),
}

# Lead lines: {row: note}, one dict per 4-bar pattern.
LEADS = {
    "verse1": {0: "A5", 3: "A5", 6: "C6", 8: "E6", 12: "D6", 14: "C6",
               16: "C6", 19: "A5", 22: "C6", 24: "F6", 28: "E6", 30: "C6",
               32: "D6", 35: "B5", 38: "D6", 40: "G6", 44: "F6", 46: "D6",
               48: "E6", 51: "E6", 54: "D6", 56: "C6", 58: "B5", 60: "A5"},
    "verse2": {0: "E6", 3: "E6", 6: "A6", 8: "G6", 12: "E6", 14: "D6",
               16: "F6", 19: "C6", 22: "F6", 24: "A6", 28: "G6", 30: "F6",
               32: "G6", 35: "D6", 38: "G6", 40: "B6", 44: "A6", 46: "G6",
               48: "A6", 56: "E6", 58: "G6", 60: "A6"},
    "run":    {0: "A5", 2: "C6", 4: "F6", 6: "C6", 8: "A5", 10: "C6", 12: "F6", 14: "A6",
               16: "B5", 18: "D6", 20: "G6", 22: "D6", 24: "B5", 26: "D6", 28: "G6", 30: "B6",
               32: "E6", 34: "G6", 36: "B6", 38: "G6", 40: "E6", 42: "G6", 44: "D6", 46: "E6",
               48: "C6", 50: "E6", 52: "A6", 60: "G6", 62: "E6"},
    "run2":   {0: "A5", 2: "C6", 4: "F6", 6: "C6", 8: "A5", 10: "C6", 12: "F6", 14: "A6",
               16: "B5", 18: "D6", 20: "G6", 22: "D6", 24: "B5", 26: "D6", 28: "G6", 30: "B6",
               32: "A6", 34: "F6", 36: "D6", 38: "F6", 40: "A6", 42: "D7", 44: "C7", 46: "A6",
               48: "B6", 50: "G#6", 52: "E6", 54: "G#6", 56: "B6", 58: "D7", 60: "E7"},
    "chorus1": {0: "G6", 6: "E6", 8: "G6", 12: "C7",
                16: "B6", 22: "G6", 24: "D6", 28: "G6",
                32: "A6", 38: "E6", 40: "A6", 44: "C7", 46: "B6",
                48: "A6", 52: "F6", 56: "A6", 60: "C7"},
    "chorus2": {0: "G6", 6: "E6", 8: "G6", 12: "C7",
                16: "B6", 22: "G6", 24: "D7", 28: "B6",
                32: "A6", 36: "F6", 40: "C7", 44: "A6",
                48: "B6", 52: "D7", 56: "G6", 58: "A6", 60: "B6", 62: "D7"},
}

# (lead or None, chords for the 4 bars, drum fill at the end?)
SECTIONS = {
    "intro":   (None,      ["Am", "Am", "F", "G"], True),
    "verse1":  ("verse1",  ["Am", "F", "G", "Am"], False),
    "verse2":  ("verse2",  ["Am", "F", "G", "Am"], True),
    "run":     ("run",     ["F", "G", "Em", "Am"], False),
    "run2":    ("run2",    ["F", "G", "Dm", "E"], True),
    "chorus1": ("chorus1", ["C", "G", "Am", "F"], False),
    "chorus2": ("chorus2", ["C", "G", "F", "G"], True),
}
ORDER = ["intro", "verse1", "verse2", "verse1", "verse2", "run", "run2",
         "chorus1", "chorus2", "chorus1", "chorus2", "run", "run2"]

KICK, SNARE, HAT = ("C_6", 3), ("F#4", 2), ("E_3", 1)
REST = ("___", 0)


def lead_rows(name):
    rows = [REST] * ROWS
    if name:
        for r, n in LEADS[name].items():
            rows[r] = (unsemis(semis(n) - 12), 1)     # written an octave above where it sounds
    return rows


def arp_rows(chords):
    rows = []
    shape = [0, 1, 2, 3, 2, 1, 2, 3, 0, 1, 2, 3, 2, 3, 2, 1]
    for ch in chords:
        tones = CHORDS[ch][1]
        rows += [(note(tones[i]), 2) for i in shape]
    return rows


def bass_rows(chords):
    rows = []
    for ch in chords:
        root = semis(CHORDS[ch][0])
        for beat in range(4):                     # gallop: low . high low
            rows += [(unsemis(root), 1), ("___", 0), (unsemis(root + 12), 1), (unsemis(root), 1)]
    return rows


def drum_rows(fill):
    bar = {0: KICK, 2: HAT, 4: SNARE, 6: HAT, 8: KICK, 10: KICK, 12: SNARE, 14: HAT}
    rows = []
    for b in range(4):
        for r in range(16):
            hit = bar.get(r)
            if fill and b == 3 and r >= 8:
                hit = SNARE if r % 2 == 0 or r >= 12 else KICK
            rows.append(hit if hit else ("___", 0))
    return rows


def instrument(kind, name, **fields):
    ins = uge.blank_instrument(kind)
    ins["name"] = name
    ins.update(fields)
    return ins


def main():
    song = uge.blank_song()
    song["name"], song["artist"] = "Race theme", "fsub"
    song["comment"] = "First draft written by tools/compose_race.py"
    song["tempo"] = TEMPO
    song["duty"][0] = instrument(0, "Lead", duty=2, volume=11, vol_dir=1, vol_change=3)
    song["duty"][1] = instrument(0, "Arpeggio", duty=1, volume=7, vol_dir=1, vol_change=1)
    song["wave"][0] = instrument(1, "Bass", wave_volume=1, wave=0)
    song["noise"][0] = instrument(2, "Hat", volume=6, vol_dir=1, vol_change=3,
                                  length=8, length_enabled=True)
    song["noise"][1] = instrument(2, "Snare", volume=12, vol_dir=1, vol_change=2,
                                  length=16, length_enabled=True)
    song["noise"][2] = instrument(2, "Kick", volume=15, vol_dir=1, vol_change=1,
                                  length=24, length_enabled=True)
    song["waves"][0] = [15 - i // 2 for i in range(32)]        # sawtooth

    ids = {}
    for name, (lead, chords, fill) in SECTIONS.items():
        for ch, rows in enumerate((lead_rows(lead), arp_rows(chords),
                                   bass_rows(chords), drum_rows(fill))):
            assert len(rows) == ROWS
            cells = []
            for n, inst in rows:
                c = uge.blank_cell()
                if n != "___":
                    c["note"], c["instrument"] = uge.NOTE_NAMES.index(n), inst
                cells.append(c)
            ids[name, ch] = len(song["patterns"])
            song["patterns"][ids[name, ch]] = cells
    for ch in range(4):
        song["orders"][ch] = [ids[name, ch] for name in ORDER]
    with open(sys.argv[1], "wb") as f:
        f.write(uge.write(song))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Compose first drafts of the other tracks' themes and save them as hUGETracker songs.

Like compose_race.py this only seeds the .uge files: from then on each .uge is the song.
Open it in hUGETracker, edit, save, rebuild.  Running this again overwrites those edits.

Each song is four channels, 16th-note rows, 4 bars per pattern: lead, chord arpeggio, wave
bass, drums.  The lead is written by rule from the chords and a scale (chord notes on the
beats, steps and small leaps between), from a fixed seed, so it comes out the same each time.

usage: compose_songs.py MUSICDIR
"""
import os
import random
import sys

import uge

ROWS = 64
PC = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9,
      "A#": 10, "B": 11}
KICK, SNARE, HAT = (36, 3), (18, 2), (4, 1)      # (noise note, instrument)

SONGS = {
    "ocean": dict(          # BLUE DEEP: bright, rolling, in D
        title="Blue Deep", tempo=6, seed=11, scale="D E F# G A B C#",
        chords={"D": "D F# A", "A": "A C# E", "Bm": "B D F#", "G": "G B D", "Em": "E G B"},
        sections={"a": "D A Bm G", "b": "G A D Bm", "c": "Em G D A", "d": "G A Bm Bm"},
        order="a- a b a c b d a".split(), low=45, high=62,
        rhythms=[[0, 6, 8, 12], [0, 4, 8, 10, 12], [0, 8, 12, 14], [0, 3, 6, 8, 12], [0, 8]],
        bass=[0, None, None, 0, 12, None, 0, None], arp=[0, 1, 2, 3, 2, 3, 2, 1],
        drums={0: KICK, 4: HAT, 8: SNARE, 10: KICK, 12: HAT, 14: HAT},
        lead=dict(duty=2, volume=10, vol_change=4), arp_inst=dict(duty=1, volume=6, vol_change=2),
        wave=[15, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1] * 2),
    "wind": dict(           # GOLD WIND: a gallop in E minor
        title="Gold Wind", tempo=5, seed=23, scale="E F# G A B C D",
        chords={"Em": "E G B", "C": "C E G", "G": "G B D", "D": "D F# A", "Am": "A C E",
                "B": "B D# F#"},
        sections={"a": "Em Em C D", "b": "Em G D Em", "c": "C D Em Em", "d": "Am B Em Em"},
        order="a- a b a b c d c d".split(), low=47, high=64,
        rhythms=[[0, 2, 3, 4, 8, 10, 11, 12], [0, 3, 4, 6, 8, 12], [0, 2, 3, 4, 6, 7, 8],
                 [0, 4, 6, 7, 8, 12, 14]],
        bass=[0, None, 0, 0, 12, None, 0, 0], arp=[0, 2, 1, 2, 3, 2, 1, 2],
        drums={0: KICK, 2: HAT, 3: KICK, 4: SNARE, 6: HAT, 7: KICK, 8: KICK, 10: HAT, 11: KICK,
               12: SNARE, 14: HAT},
        lead=dict(duty=1, volume=11, vol_change=3), arp_inst=dict(duty=2, volume=6, vol_change=1),
        wave=[15] * 8 + [0] * 8 + [15] * 4 + [0] * 12),
    "port": dict(           # OLD PORT: tense and syncopated, D harmonic minor
        title="Old Port", tempo=5, seed=37, scale="D E F G A A# C#",
        chords={"Dm": "D F A", "Bb": "A# D F", "C": "C E G", "A": "A C# E", "Gm": "G A# D"},
        sections={"a": "Dm Dm Bb A", "b": "Dm C Bb A", "c": "Gm Dm A Dm", "d": "Bb C A A"},
        order="a- a b a b c d c".split(), low=45, high=62,
        rhythms=[[0, 3, 6, 10, 12], [2, 4, 7, 8, 11, 14], [0, 3, 6, 8, 11, 14], [0, 6, 7, 8, 14]],
        bass=[0, None, 7, None, 12, None, 7, 0], arp=[0, 1, 2, 1, 3, 2, 1, 2],
        drums={0: KICK, 3: HAT, 4: SNARE, 6: HAT, 8: KICK, 9: KICK, 11: HAT, 12: SNARE, 15: SNARE},
        lead=dict(duty=3, volume=11, vol_change=3), arp_inst=dict(duty=0, volume=7, vol_change=1),
        wave=[0, 3, 6, 9, 12, 15, 12, 9, 6, 3, 0, 5, 10, 15, 10, 5] * 2),
}


def tones(names):
    return [PC[n] for n in names.split()]


def nearest(pitch, classes, low, high):
    """The pitch nearest to `pitch` whose pitch class is one of `classes`."""
    best = None
    for p in range(low, high + 1):
        if p % 12 in classes and (best is None or abs(p - pitch) < abs(best - pitch)):
            best = p
    return best


def write_lead(song, chords, rng, at):
    """One 4-bar lead: a chord note on each bar's first note, scale steps and leaps after."""
    rows = {}
    scale = tones(song["scale"])
    for bar, name in enumerate(chords):
        rhythm = rng.choice(song["rhythms"])
        for k, r in enumerate(rhythm):
            if k == 0 or (r % 8 == 0 and rng.random() < 0.6):
                at = nearest(at + rng.choice((-2, 0, 0, 3)), tones(song["chords"][name]),
                             song["low"], song["high"])
            else:
                step = rng.choice((-2, -1, -1, 1, 1, 2))
                ladder = [p for p in range(song["low"], song["high"] + 1) if p % 12 in scale]
                i = min(range(len(ladder)), key=lambda j: abs(ladder[j] - at))
                at = ladder[max(0, min(len(ladder) - 1, i + step))]
            rows[bar * 16 + r] = at
    return rows, at


def compose(key, song, outdir):
    rng = random.Random(song["seed"])
    u = uge.blank_song()
    u["name"], u["artist"] = song["title"], "fsub"
    u["comment"] = "First draft written by tools/compose_songs.py"
    u["tempo"] = song["tempo"]

    def instrument(kind, name, **fields):
        ins = uge.blank_instrument(kind)
        ins["name"] = name
        ins.update(fields)
        return ins

    u["duty"][0] = instrument(0, "Lead", vol_dir=1, **song["lead"])
    u["duty"][1] = instrument(0, "Arpeggio", vol_dir=1, **song["arp_inst"])
    u["wave"][0] = instrument(1, "Bass", wave_volume=1, wave=0)
    u["noise"][0] = instrument(2, "Hat", volume=6, vol_dir=1, vol_change=3, length=8, length_enabled=True)
    u["noise"][1] = instrument(2, "Snare", volume=12, vol_dir=1, vol_change=2, length=16, length_enabled=True)
    u["noise"][2] = instrument(2, "Kick", volume=15, vol_dir=1, vol_change=1, length=24, length_enabled=True)
    u["waves"][0] = list(song["wave"])

    def pattern(notes):                           # {row: (note, instrument)} -> its number
        cells = [uge.blank_cell() for _ in range(ROWS)]
        for r, (n, inst) in notes.items():
            cells[r]["note"], cells[r]["instrument"] = n, inst
        u["patterns"][len(u["patterns"])] = cells
        return len(u["patterns"]) - 1

    made = {}
    at = (song["low"] + song["high"]) // 2
    for name in dict.fromkeys(song["order"]):
        chords = song["sections"][name.rstrip("-")].split()
        lead = {}
        if not name.endswith("-"):                # "x-" is section x without the lead: an intro
            lead, at = write_lead(song, chords, rng, at)
        arp, bass, drums = {}, {}, {}
        for bar, ch in enumerate(chords):
            cls = tones(song["chords"][ch])
            ladder = [p for p in range(33, 58) if p % 12 in cls]
            root = nearest(12, [cls[0]], 0, 23)   # bass octave
            for r in range(16):
                arp[bar * 16 + r] = (ladder[song["arp"][r % 8] + (r // 8)], 2)
                b = song["bass"][r % 8]
                if b is not None:
                    bass[bar * 16 + r] = (root + b, 1)
                if r in song["drums"]:
                    drums[bar * 16 + r] = song["drums"][r]
            if bar == 3 and name.rstrip("-") in ("b", "d"):   # a fill into the next section
                for r in range(8, 16):
                    drums[48 + r] = SNARE if r % 2 == 0 or r >= 12 else KICK
        made[name] = (pattern({r: (n - 12, 1) for r, n in lead.items()}), pattern(arp),
                      pattern(bass), pattern(drums))
    for ch in range(4):
        u["orders"][ch] = [made[name][ch] for name in song["order"]]
    with open(os.path.join(outdir, key + ".uge"), "wb") as f:
        f.write(uge.write(u))


if __name__ == "__main__":
    for key, song in SONGS.items():
        compose(key, song, sys.argv[1])
        print("composed", key)

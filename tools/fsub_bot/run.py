#!/usr/bin/env python3
"""Race fsub with the SNES F-Zero bot's own policy (tools/racing/policy.py).

fsub's driving is F-Zero's scaled down (tools/gen_physics.py: S fsub units to F-Zero's one),
so this adapter only changes units: it builds fsub's course as a line of points in F-Zero
units (fsub's corners have true curvatures: gen_tracks.py), reports fsub's surfaces through
the same lookup the SNES bot reads tiles with, observes the car every frame in F-Zero units,
and presses fsub's buttons for the policy's controls.  The policy's numbers are F-Zero's,
untouched.

  .venv/bin/python tools/fsub_bot/run.py [--track N] [--car N] [--level N] [--output result.json]

Needs PyBoy (pip install pyboy) and a built fzero.gb with its fzero.sym.
"""
import argparse
import json
import math
import pathlib
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent))
from racing.policy import (Course, DASH_PAD, DIRT, JUMP_PAD, OFF, ROAD, SAMPLE_SPACING,  # noqa: E402
                           Observation, Policy)

S = 8.0 / 8.81                 # fsub units per F-Zero unit (gen_physics.py)
LATERAL = 0.75                 # ...and across the road, three quarters of that again: the car crosses
                               # it at 3/4 (fzero.asm Steer), so the road is as wide as F-Zero's
STEP = 2 * math.pi / 192       # radians in an angle step
CHUNK, CHUNKS = 256, 64
LAP = CHUNK * CHUNKS
ROAD_HALF = 84                 # fsub units (gen_gfx.py ROAD)
PLAYER_Z = 175                 # the car is this far ahead of the camera
LEAD = 3                       # a thing appears LEAD chunks before it sits (gen_tracks.py)
PATCH_X, PATCH_HALF = 18, 24   # dirt, pads, recharge strips and ramps: their middle, and how
                               # far either side of it they act (fzero.asm PATCH_X, PATCH_HALF)
MET_BEFORE, MET_AFTER = 64, 8  # a thing listed at chunk k is met at k * 256 - 10: this much road
                               # around that is where it acts, for planning
BARRIER_HALF = 13              # a barrier knocks a car this near its lane's middle
RIVAL_LANES = (-54, -18, 18, 54)
LANE_EDGE = -9                 # left of this at the tunnel's mouth: into the tunnel
# fsub's "things" (fzero.asm MOUTH.., the table value)
MOUTH, BARRIER = 1, 2
DIRT_L, DIRT_R, PAD_L, PAD_R, HEAL_L, HEAL_R, JUMP_L, JUMP_R = 6, 7, 8, 9, 10, 11, 12, 13
BUTTONS = {'GAS': 'b', 'BRAKE': 'a', 'LEFT': 'left', 'RIGHT': 'right', 'LEAN_LEFT': 'a',
           'LEAN_RIGHT': 'a', 'BOOST': 'up', 'NOSE_UP': 'down', 'NOSE_DOWN': 'up'}


def load_symbols(path):
    syms = {}
    for line in open(path):
        parts = line.split()
        if len(parts) == 2 and ':' in parts[0]:
            syms[parts[1]] = int(parts[0].split(':')[1], 16)
    return syms


class FsubCourse(Course):
    """fsub's race as F-Zero would see it: the centre line, a point every SAMPLE_SPACING F-Zero
    units, from the corners' true curvature; and what is on the road where.

    An fsub lap turns 360 degrees but need not close: its straights are as long as they are,
    with no map to fit.  So the race is laid out as its laps end to end, each picking up where
    the last left off, and no corner is bent to make it meet itself.  (The policy's course is
    a loop; its seam, the end of the last lap, is never reached.)"""

    def __init__(self, bends, things, laps):
        self.things = things
        step = SAMPLE_SPACING * S                          # fsub units between points
        per_lap = round(LAP / step)
        step = LAP / per_lap
        heading, point, raw = 0.0, np.zeros(2), []
        for i in range(per_lap * laps):
            raw.append(point.copy())
            level = (bends[int(i * step // CHUNK) % CHUNKS] & 127) - 32
            heading += level * 3 / 256 * STEP * step       # (radians a fsub unit, times the step)
            point = point + np.array([math.sin(heading), -math.cos(heading)]) * step
        self.step, self.per_lap = step, per_lap
        self.gap = point / laps - np.zeros(2)              # (how far a lap is from closing)
        self.centre = np.array(raw) / S                    # F-Zero units
        tangent = np.roll(self.centre, -1, axis=0) - np.roll(self.centre, 1, axis=0)
        self.centre_heading = np.arctan2(tangent[:, 0], -tangent[:, 1])
        tangent /= np.linalg.norm(tangent, axis=1)[:, None]
        self.centre_normal = np.column_stack((-tangent[:, 1], tangent[:, 0]))
        # a coarse grid of the points, to find the nearest quickly
        self.cell = 64
        self.grid = {}
        for i, (x, y) in enumerate(self.centre):
            self.grid.setdefault((int(x // self.cell), int(y // self.cell)), []).append(i)
        self.hint = 0
        super().__init__(self.centre.copy(), self.surface_at, lap_samples=per_lap)

    def nearest(self, point):
        """The centre point nearest this one: of those near the last found (another lap, or
        another part of this one, may pass close by), else of all."""
        cx, cy = int(point[0] // self.cell), int(point[1] // self.cell)
        near, far = (0, float('inf')), (0, float('inf'))
        size = len(self.centre)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for i in self.grid.get((cx + dx, cy + dy), ()):
                    d = (self.centre[i][0] - point[0]) ** 2 + (self.centre[i][1] - point[1]) ** 2
                    if d < far[1]:
                        far = (i, d)
                    if min((i - self.hint) % size, (self.hint - i) % size) < 300 and d < near[1]:
                        near = (i, d)
        best = near if near[1] < float('inf') else far
        if best[1] == float('inf'):                        # (far off the road)
            best = (int(np.argmin(np.sum((self.centre - point) ** 2, axis=1))), 0)
        self.hint = best[0]
        return best[0]

    def where(self, point):
        """(fsub units along the race, fsub units across the road) of a point in F-Zero units."""
        i = self.nearest(point)
        offset = (np.asarray(point) - self.centre[i]) * S
        along = i * self.step + offset @ np.array([self.centre_normal[i][1], -self.centre_normal[i][0]])
        return along, offset @ self.centre_normal[i] * LATERAL

    def thing_at(self, along):
        """What sits on the road here, or 0.  (The game tests a thing once, as the car meets
        it: a thing listed at chunk k, LEAD chunks before it is met, at k * 256 - 10.)"""
        k = round(along / CHUNK)
        if not -MET_BEFORE <= along - k * CHUNK <= MET_AFTER:
            return 0
        return self.things[(k - LEAD) % CHUNKS]

    def surface_at(self, point):
        along, x = self.where(point)
        if abs(x) > ROAD_HALF:
            return OFF
        kind = self.thing_at(along)
        if kind >= DIRT_L:                                 # a patch: left ones are even
            if abs(x - (-PATCH_X if kind % 2 == 0 else PATCH_X)) > PATCH_HALF:
                return ROAD
            return {DIRT_L: DIRT, DIRT_R: DIRT, PAD_L: DASH_PAD, PAD_R: DASH_PAD,
                    JUMP_L: JUMP_PAD, JUMP_R: JUMP_PAD}.get(kind, ROAD)
        if BARRIER <= kind < BARRIER + 4 and abs(x - RIVAL_LANES[kind - BARRIER]) <= BARRIER_HALF:
            return OFF                                     # (a barrier: as bad as off the road)
        if kind == MOUTH and x < LANE_EDGE:
            return OFF                                     # (the tunnel: the bot keeps to the course)
        return ROAD

    def point(self, along, x):
        """F-Zero units, from fsub's along-the-race and across-the-road."""
        i = int(along / self.step) % len(self.centre)
        return self.centre[i] + self.centre_normal[i] * (x / S / LATERAL)

    def heading_at(self, along):
        i = int(along / self.step) % len(self.centre)
        return self.centre_heading[i]


class Fsub:
    def __init__(self, rom, syms):
        from pyboy import PyBoy
        self.pb = PyBoy(str(rom), window='null', sound_emulated=False)
        self.pb.set_emulation_speed(0)
        self.m = self.pb.memory
        self.s = syms
        self.held = set()

    def rd(self, name, offset=0):
        return self.m[self.s[name] + offset]

    def word(self, name, signed=True):
        v = self.rd(name) | self.rd(name, 1) << 8
        return v - 65536 if signed and v & 0x8000 else v

    def hold(self, buttons):
        for b in self.held - buttons:
            self.pb.button_release(b)
        for b in buttons - self.held:
            self.pb.button_press(b)
        self.held = set(buttons)

    def tick(self, n=1):
        for _ in range(n):
            self.pb.tick()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--rom', type=pathlib.Path, default=ROOT / 'fzero.gb')
    ap.add_argument('--track', type=int, default=0)
    ap.add_argument('--car', type=int, default=0)
    ap.add_argument('--level', type=int, default=3)
    ap.add_argument('--mode', type=int, default=0, help='0 RACE, 3 LEARN')
    ap.add_argument('--max-frames', type=int, default=20000)
    ap.add_argument('--output', type=pathlib.Path)
    ap.add_argument('--log', type=pathlib.Path, help='write a frame-by-frame log (.npz)')
    ap.add_argument('--peaks', type=int, default=0, help='print the frames whose load reaches this many lines')
    ap.add_argument('--gif', nargs=3, metavar=('PATH', 'FROM', 'TO'), help='record race frames FROM..TO as an animated GIF')
    args = ap.parse_args()

    g = Fsub(args.rom, load_symbols(args.rom.with_suffix('.sym')))
    g.tick(120)
    for name, value in (('hTrackNo', args.track), ('wCar', args.car), ('hLevel', args.level), ('hMode', args.mode)):
        g.m[g.s[name]] = value
    g.m[g.s['wMenuDirty']] = 1
    g.tick(4)
    g.hold({'start'}); g.tick(4); g.hold(set()); g.tick(30)
    bends = [g.rd('wTrackBend', i) for i in range(CHUNKS)]
    things = [g.rd('wChunkSpawn', i) for i in range(CHUNKS)]
    course = FsubCourse(bends, things, laps=g.rd('hLaps') + 2)
    policy = Policy(course)

    last_point, was_air, was_boost, log = None, False, False, []
    frames, camera, last_pos = 0, 0, None              # (camera: how far it has come, unwrapped)
    load = dict(peak=0, sum=0, n=0, dropped=0, repeats=0, last=None, front=None)   # (the game's hLoad: the line its work ended on)
    gif_frames = []
    while frames < args.max_frames:
        frames += 1
        racing = not g.rd('hCount') and not g.rd('hState')
        if g.rd('hState'):
            break
        if racing:
            ld = g.rd('hLoad')
            lines = ld - 144 if ld >= 144 else ld + 10
            load['peak'] = max(load['peak'], lines); load['sum'] += lines; load['n'] += 1
            if args.peaks and lines >= args.peaks:
                print('peak', lines, 'frame', frames, 'chunk', int(along % LAP) >> 8, 'rivals shown',
                      sum(1 for r in range(7) if g.m[g.s['wRivals'] + r * 8 + 7]), 'air', g.rd('hAir'),
                      'objs', [g.rd('wObjSlots', k * 4) for k in range(2)], 'corner lines', g.rd('hFarLines'),
                      'flying', g.rd('wFlying'), 'sfx', g.rd('wSfxPtr', 1), 'wind', g.rd('wWind', g.rd('hChunk')))
            f = g.rd('hFrame')
            if load['last'] is not None and (f - load['last']) & 255 != 1:
                load['dropped'] += 1
                if args.peaks:
                    print('drop at frame', frames, 'chunk', int(along % LAP) >> 8, 'load line', ld)
            load['last'] = f
            front = g.rd('hFront')              # (a picture shown twice: its frame missed VBlank)
            if load['front'] is not None and front == load['front']:
                load['repeats'] += 1
                if args.peaks:
                    print('repeat at frame', frames, 'chunk', int(along % LAP) >> 8)
            load['front'] = front
        speed = g.word('hSpeed', signed=False) / 256 / S
        pos = (g.rd('hPos', 1) | g.rd('hPos', 2) << 8)
        if last_pos is not None:
            camera += (pos - last_pos + LAP // 2) % LAP - LAP // 2
        last_pos = pos
        along = camera + PLAYER_Z                      # the car, along the race
        x = g.word('hX') / 256
        point = course.point(along, x)
        course.hint = int(along / course.step)
        track_heading = course.heading_at(along)
        air = bool(g.rd('hAir'))
        boost = g.rd('hBoost') > 0
        chunk = g.rd('hChunk')
        windy = g.rd('wWind', chunk) != 0 if 'wWind' in g.s else False
        velocity = (point - last_point) if last_point is not None else np.zeros(2)
        rivals = []
        for r in range(7):
            base = g.s['wRivals'] + r * 8
            d = g.m[base + 1] | g.m[base + 2] << 8
            d = d - 65536 if d & 0x8000 else d
            if d < -30000 or d > 2600:
                continue
            lane = g.m[base + 5]
            if lane & 0x40:
                rx = g.m[base + 3]
                rx = rx - 256 if rx & 0x80 else rx
            else:
                rx = RIVAL_LANES[lane & 3]
            rivals.append(course.point(max(0, camera + d), rx))
        obs = Observation(
            racing=racing, speed=speed, position=point,
            facing=track_heading + g.word('wFacing') / 256 * STEP,
            momentum=track_heading + g.word('wMomentum') / 256 * STEP,
            turn_rate=g.word('wTurning') / 256 * STEP,
            airborne=air, dashing=boost, boosts=g.rd('hBoosts'), boost_blocked=boost,
            height=g.word('hZ', signed=False) * 8 / S, vertical_speed=g.word('hVZ') * 8 / S,
            velocity=velocity, windy=windy,
            surface_under=DIRT if g.rd('hDirt') else ROAD,
            jump_started=air and not was_air, dash_started=boost and not was_boost and not air,
            rivals=rivals)
        controls = policy.decide(obs)
        keys = set()
        for c in controls:
            if c == 'BOOST' and air:
                continue
            keys.add(BUTTONS[c])
        if air:                                            # (the nose, not the boost or brake)
            keys.discard('a')
        g.hold(keys)
        if args.log:
            log.append([frames, along % LAP, x, speed * S, g.word('wFacing') / 256, g.word('wMomentum') / 256,
                        g.word('wTurning') / 256, int(air), g.rd('hHealth'), g.rd('hRank'), g.rd('hLap'),
                        int('b' in keys), int('a' in keys), int('left' in keys), int('right' in keys),
                        int('up' in keys), int('down' in keys), g.rd('wWall'), course.entry_speed[policy.index] * S, policy.lane * S,
                        len(rivals)])
        last_point, was_air, was_boost = point, air, boost
        g.tick()
        if args.gif and int(args.gif[1]) <= frames < int(args.gif[2]) and frames % 2 == 0:
            gif_frames.append(g.pb.screen.image.convert('RGB').resize((320, 288)))
    state = g.rd('hState')
    result = {
        'track': args.track, 'car': args.car, 'level': args.level,
        'outcome': {0: 'timeout', 1: 'finished', 2: 'wrecked', 3: 'ranked out'}[state],
        'place': g.rd('hRank'), 'laps': g.rd('hLap'), 'health': g.rd('hHealth'),
        'frames': frames, 'driving': policy.summary(),
        'load': {'peak_lines': load['peak'], 'peak_pct': round(load['peak'] / 1.54, 1),
                 'mean_pct': round(load['sum'] / max(1, load['n']) / 1.54, 1), 'dropped': load['dropped'],
                 'repeats': load['repeats']},
    }
    print(json.dumps(result))
    if gif_frames:
        gif_frames[0].save(args.gif[0], save_all=True, append_images=gif_frames[1:], duration=33, loop=0, optimize=True)
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    if args.log:
        np.savez(args.log, rows=np.array(log),
                 cols=np.array('frame along x speed facing momentum turning air health rank lap B A L R U D wall entry lane rivals'.split()))


if __name__ == '__main__':
    main()

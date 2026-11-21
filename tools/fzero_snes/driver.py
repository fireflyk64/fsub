"""SNES F-Zero's side of the racing bot: race state from the game's work RAM, and the shared
policy's controls (tools/racing/policy.py) as SNES buttons."""

import pathlib
import sys
from struct import unpack_from

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from racing.policy import (Course, DASH_PAD, DIRT, JUMP_PAD, OFF, ROAD, SAMPLE_SPACING,  # noqa: E402
                           Observation, Policy)

# Offsets in the emulator's $7E0000-$7FFFFF work RAM block.
RACE_PHASE = 0x55
RACING = 3
RACE_STATE = 0xC3
RACE_ENDED = 0xE0
POSITION_X = 0xB70
POSITION_Y = 0xB90
SPEED = 0xB20
VELOCITY_X = 0xB30
VELOCITY_Y = 0xB50
VERTICAL_SPEED = 0xBB0
HEIGHT = 0xBC0
FACING = 0xBD0
MOMENTUM = 0xBE0
TURN_RATE = 0xC10
SPIN = 0xC20
VEHICLE_PRESENT = 0xB00
VEHICLE_ACTION = 0xB10
SURFACE_FLAGS = 0xC7
GROUND_FLAGS = 0xCC0
TILE_UNDER_CAR = 0xCD0
LAP = 0xD40
SURFACE = 0xD50
VEHICLE_STATE = 0xD51
PLACE = 0xDC8
BOOSTS = 0xCF3

ANGLE_UNIT = np.pi / 24576  # One turn is $C000.

# The shared policy's controls, as SNES buttons.
BUTTONS = {'GAS': 'B', 'BRAKE': 'Y', 'LEFT': 'LEFT', 'RIGHT': 'RIGHT', 'LEAN_LEFT': 'L',
           'LEAN_RIGHT': 'R', 'BOOST': 'A', 'NOSE_UP': 'DOWN', 'NOSE_DOWN': 'UP'}


def word(ram, address):
    return unpack_from('<H', ram, address)[0]


def signed_word(ram, address):
    return unpack_from('<h', ram, address)[0]


def is_dirt(tile):
    return 0xA7 <= tile < 0xB0 or 0xCC <= tile < 0xD0


def is_jump_pad(tile):
    return 0xBA <= tile < 0xC0


def is_dash_pad(tile):
    return 0xC3 <= tile < 0xC8


def is_road(tile):
    return 0x82 <= tile < 0xD0 and tile != 0xA5 and not is_dirt(tile)


def surface_of(tile):
    if is_dirt(tile):
        return DIRT
    if is_jump_pad(tile):
        return JUMP_PAD
    if is_dash_pad(tile):
        return DASH_PAD
    return ROAD if is_road(tile) else OFF


def read_tiles(ram):
    # Bank $7F contains the 32x16 chunk grid and its tile dictionaries.
    # Each chunk points to 16 rows of 2x2 tile groups, in column-major order.
    bank = np.frombuffer(ram, dtype=np.uint8, offset=0x10000)

    def bank_words(address):
        return (bank[address & 0xFFFF].astype(int) |
                (bank[(address + 1) & 0xFFFF].astype(int) << 8))

    grid = word(ram, 0xB0)
    if grid not in (0x4C00, 0x4E00):
        raise ValueError('The game has not loaded its track tile grid')
    x = np.arange(1024)[None, :]
    y = np.arange(512)[:, None]
    chunks = bank[grid + (y // 32) * 32 + x // 32].astype(int)
    rows = bank_words(0x5000 + chunks * 32 + (y // 2 % 16) * 2)
    groups = bank_words(rows + (x // 2 % 16) * 2)
    return bank[(groups + (x % 2) * 2 + y % 2) & 0xFFFF]


class SnesCourse(Course):
    def __init__(self, ram):
        self.tiles = read_tiles(ram)

        # The game loads separate X and Y checkpoint arrays in race order.
        # The closing point gives the road center at the starting gate.
        count = ram[0xAD] + 1
        if count < 3:
            raise ValueError('The game has not loaded its race checkpoints')
        gates = np.array([
            (word(ram, 0x11FE + i * 2), word(ram, 0x13FE + i * 2))
            for i in range(count + 1)
        ], dtype=float)
        gates[0] = gates[-1]

        distances = np.r_[0, np.cumsum(np.linalg.norm(np.diff(gates, axis=0), axis=1))]
        samples = np.linspace(0, distances[-1], int(distances[-1] / SAMPLE_SPACING),
                              endpoint=False)
        raw_line = np.column_stack([np.interp(samples, distances, axis) for axis in gates.T])
        super().__init__(raw_line, lambda point: surface_of(self.tile_at(point)))

    def tile_at(self, point):
        x, y = point
        return int(self.tiles[int(y) // 8 % 512, int(x) // 8 % 1024])


class Driver:
    """The bot for one race: Driver(ram) once the countdown is on, then buttons(ram) a frame."""

    def __init__(self, ram):
        self.course = SnesCourse(ram)
        self.policy = Policy(self.course)
        self.airborne = False
        self.dashing = False

    @property
    def index(self):
        return self.policy.index

    @property
    def stats(self):
        return self.policy.stats

    def observe(self, ram):
        speed = word(ram, SPEED) / 256
        if ram[RACE_PHASE] != RACING:
            return Observation(racing=False, speed=speed, position=None, facing=0, momentum=0,
                               turn_rate=0)
        state = ram[VEHICLE_STATE]
        airborne = bool(state & 0x80)
        dashing = bool(state & 0x20)
        jump_started = airborne and not self.airborne and is_jump_pad(ram[TILE_UNDER_CAR])
        dash_started = dashing and not self.dashing and is_dash_pad(ram[TILE_UNDER_CAR])
        self.airborne, self.dashing = airborne, dashing
        on_dirt = not airborne and ram[SURFACE] & 0x80 and not ram[GROUND_FLAGS] & 0xE0
        action = ram[VEHICLE_ACTION]
        turn_direction = 1 if action & 1 else -1 if action & 2 else 0
        spin = word(ram, SPIN)
        spinning = (1 if spin & 0x8000 else -1) if state & 0x40 and spin & 0x7FFF else 0
        windy = bool(ram[SURFACE_FLAGS] & 0x60)
        velocity = None
        if windy:
            vx = signed_word(ram, VELOCITY_X) + word(ram, VELOCITY_X + 0x10) / 65536
            vy = signed_word(ram, VELOCITY_Y) + word(ram, VELOCITY_Y + 0x10) / 65536
            velocity = np.array([vx, vy])
        rivals = [np.array([word(ram, POSITION_X + slot), word(ram, POSITION_Y + slot)])
                  for slot in range(2, 10, 2) if ram[VEHICLE_PRESENT + slot] & 0x80]
        return Observation(
            racing=True, speed=speed,
            position=np.array([word(ram, POSITION_X), word(ram, POSITION_Y)]),
            facing=word(ram, FACING) * ANGLE_UNIT, momentum=word(ram, MOMENTUM) * ANGLE_UNIT,
            turn_rate=word(ram, TURN_RATE) * ANGLE_UNIT * turn_direction,
            airborne=airborne, dashing=dashing, spinning=spinning,
            height=max(0, word(ram, HEIGHT) - 0x400), vertical_speed=signed_word(ram, VERTICAL_SPEED),
            boosts=ram[BOOSTS], boost_blocked=bool(state & 0x28), velocity=velocity, windy=windy,
            surface_under=DIRT if on_dirt else ROAD, jump_started=jump_started,
            dash_started=dash_started, rivals=rivals)

    def buttons(self, ram):
        return tuple(BUTTONS[control] for control in self.policy.decide(self.observe(ram)))

    def summary(self):
        return self.policy.summary()

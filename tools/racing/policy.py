"""The driving policy shared by the SNES F-Zero bot and fsub's.

It was written for SNES F-Zero (tools/fzero_snes/driver.py) and works in F-Zero's world
units and radians.  Each game supplies a thin adapter: the course as a line of points with a
surface lookup, and an observation of the car every frame; the policy answers with abstract
controls (GAS, BRAKE, LEFT, RIGHT, LEAN_LEFT, LEAN_RIGHT, BOOST, NOSE_UP, NOSE_DOWN) that the
adapter turns into the game's buttons.  fsub's adapter (tools/fsub_bot) converts fsub's units
to F-Zero's, so the numbers below serve both: fsub's driving is F-Zero's (gen_physics.py).

How it drives (BOT.md has more):
  1. The racing line: the course's points, rounded at the joins, with a clean lane past any
     run of dirt strips.
  2. Brake while there is still room: each bend's speed limit from its curvature, worked back
     along the approach with v_entry^2 = v_corner^2 + 2 a d.
  3. Steer toward a point ahead, farther at speed, using facing and momentum, damped by the
     turn already under way.
  4. Give traffic room: the middle or a passing offset, scored against cars and bad surface.
  5. Use the surfaces: jump plates on the line, nose up to land (or down for a bend), dash
     plates, wind, and the lap boost where there is room to use it.
"""

from dataclasses import asdict, dataclass, field
from math import cos, pi, sin, sqrt

import numpy as np

SAMPLE_SPACING = 8
CURVE_ACCELERATION = 0.17  # World units per game frame squared.
BRAKING_DECELERATION = 0.16
STEERING_LOOKAHEAD = 15  # Game frames.
STEERING_DAMPING = 7  # Account for the rotation that continues on release.
WIND_COMPENSATION = 0.45
DASH_LOOKAHEAD = 25  # Route samples.
LANDING_MARGIN = 16  # Frames to settle before the bend.
NOSE_UP_GRAVITY = 25  # Change in vertical speed per game frame.

# Surfaces the adapter's lookup reports for a point.
ROAD, DIRT, JUMP_PAD, DASH_PAD, OFF = range(5)


def heading(vector):
    return np.arctan2(vector[..., 0], -vector[..., 1])


def angle_error(angle):
    return (angle + pi) % (2 * pi) - pi


@dataclass
class DrivingStats:
    brake_frames: int = 0
    approach_brake_frames: int = 0
    jump_pad_hits: int = 0
    dash_pad_hits: int = 0
    dirt_frames: int = 0


@dataclass
class Observation:
    """The car, in F-Zero's units: world units, units a frame, radians (heading 0 is up)."""
    racing: bool
    speed: float
    position: np.ndarray
    facing: float
    momentum: float
    turn_rate: float                       # radians a frame, signed (positive: to the right)
    airborne: bool = False
    dashing: bool = False
    spinning: int = 0                      # 0, or the spin's direction (+1 / -1)
    height: float = 0                      # above the road, in the game's height units
    vertical_speed: float = 0              # ...a frame
    boosts: int = 0
    boost_blocked: bool = False            # (a boost cannot be fired now: dashing, say)
    velocity: np.ndarray = None            # where it really moved, when a wind is blowing
    windy: bool = False
    surface_under: int = ROAD
    jump_started: bool = False             # this frame it left a jump plate
    dash_started: bool = False             # ...hit a dash plate
    rivals: list = field(default_factory=list)   # their positions


class Course:
    """raw_line: the course's points SAMPLE_SPACING apart, in race order, closing on itself.
    surface(point) -> ROAD, DIRT, JUMP_PAD, DASH_PAD or OFF.  opening: the opening straight,
    in units from the start of a lap; lap_samples: points in a lap, when raw_line is several
    laps end to end (else it is one)."""

    def __init__(self, raw_line, surface, opening=(80, 360), lap_samples=None):
        self.surface = surface
        # Round the corners between the gates with a centered triangular filter.
        radius = 9
        rise = np.arange(1, radius + 2)
        weights = np.r_[rise, rise[-2::-1]]
        self.line = sum(np.roll(raw_line, i - radius, axis=0) * weight
                        for i, weight in enumerate(weights)) / weights.sum()
        self.size = len(self.line)
        self.bypass_dirt()
        surfaces = [self.surface(point) for point in self.line]
        self.jump_samples = [i for i, kind in enumerate(surfaces) if kind == JUMP_PAD]
        self.dash_samples = [i for i, kind in enumerate(surfaces) if kind == DASH_PAD]

        before = self.line - np.roll(self.line, 4, axis=0)
        after = np.roll(self.line, -4, axis=0) - self.line
        self.heading = heading(before + after)
        bend = np.abs(angle_error(heading(after) - heading(before)))
        corner_span = 8 * SAMPLE_SPACING
        self.corner_speed = np.minimum(
            11.5, np.sqrt(CURVE_ACCELERATION * corner_span / np.maximum(0.01, bend))
        )

        # Propagate every corner's speed limit back along its approach using
        # v_entry² = v_corner² + 2 * deceleration * distance.
        self.entry_speed = np.sqrt(np.min([
            np.roll(self.corner_speed, -i)**2 + 2 * BRAKING_DECELERATION * SAMPLE_SPACING * i
            for i in range(35)
        ], axis=0))

        # Reserve a boost for a run of road with room to accelerate. Prefer
        # the opening straight when it has enough room.
        boost_distance = 1200 // SAMPLE_SPACING
        self.boost_window = np.logical_and.reduce([
            np.roll(self.entry_speed, -i) >= 9.0 for i in range(boost_distance)
        ])
        start = np.arange(self.size) % (lap_samples or self.size) * SAMPLE_SPACING
        on_starting_straight = (opening[0] < start) & (start < opening[1])
        if np.any(self.boost_window & on_starting_straight):
            self.boost_window &= on_starting_straight

    def is_road(self, point):
        return self.surface(point) in (ROAD, JUMP_PAD, DASH_PAD)

    def is_dirt(self, point):
        return self.surface(point) == DIRT

    def bypass_dirt(self):
        # Some checkpoint lines cross a series of dirt strips along one side
        # of a straight. Find a clean offset for the whole series and ease in
        # and out once, so the car does not weave through individual gaps.
        dirt = np.array([i for i, point in enumerate(self.line) if self.is_dirt(point)])
        if not len(dirt):
            return
        tangent = np.roll(self.line, -4, axis=0) - np.roll(self.line, 4, axis=0)
        unit = tangent / np.linalg.norm(tangent, axis=1)[:, None]
        normals = np.column_stack((-unit[:, 1], unit[:, 0]))
        sections = np.split(dirt, np.flatnonzero(np.diff(dirt) > 8) + 1)
        taper = 18
        for section in sections:
            first, last = section[0], section[-1]
            span = np.arange(first - taper, last + taper + 1)
            indices = span % self.size
            progress = np.minimum(span - first + taper, last + taper - span) / taper
            blend = (1 - np.cos(pi * np.minimum(1, progress))) / 2
            for offset in (-24, 24, -32, 32, -40, 40):
                shifted = self.line[indices] + normals[indices] * (offset * blend[:, None])
                if all(self.is_road(point) for point in shifted):
                    self.line[indices] = shifted
                    break

    def lining_up_for_pad(self, index):
        return (any(min((pad - index) % self.size, (index - pad) % self.size) < 35
                    for pad in self.jump_samples) or
                any((pad - index) % self.size < DASH_LOOKAHEAD for pad in self.dash_samples))

    def airborne_runway(self, index, speed):
        steps = np.arange(1, round(speed * 100 / SAMPLE_SPACING) + 1)
        headings = self.heading[(index + steps) % self.size]
        turns = np.flatnonzero(abs(angle_error(headings - self.heading[index])) > 0.26)
        return steps[turns[0]] * SAMPLE_SPACING if len(turns) else float('inf')


class Policy:
    def __init__(self, course):
        self.course = course
        self.stats = DrivingStats()
        self.index = 0
        self.lane = 0.0
        self.countdown_frames = 0
        self.boost_pressed = False

    def passing_lane(self, obs, target, tangent, normal):
        threats = []
        for car in obs.rivals:
            relative = np.asarray(car, dtype=float) - obs.position
            ahead = tangent @ relative
            lateral = normal @ (relative + obs.position - target)
            if -18 < ahead < 170 and abs(lateral) < 95:
                threats.append((ahead, lateral))

        def cost(offset):
            for distance in (2, 8, 15, 23):
                point = self.course.line[(self.index + distance) % self.course.size]
                if not self.course.is_road(point + normal * offset):
                    return 10000 + abs(offset)
            traffic = sum(max(0, 39 - abs(offset - lateral)) *
                          max(0.65, 1.7 - max(ahead, 0) / 110) for ahead, lateral in threats)
            return abs(offset) * 0.48 + abs(offset - self.lane) * 0.35 + traffic

        return min((0, 40, -40), key=cost)

    def decide(self, obs):
        speed = obs.speed
        if not obs.racing:
            self.countdown_frames += 1
            # Let the engine reach launch RPM near the end of the countdown.
            return ('GAS',) if self.countdown_frames > 22 and speed < 7.9 else ()

        airborne, dashing = obs.airborne, obs.dashing
        if obs.jump_started:
            self.stats.jump_pad_hits += 1
        if obs.dash_started:
            self.stats.dash_pad_hits += 1
        if not airborne and obs.surface_under == DIRT:
            self.stats.dirt_frames += 1

        position = obs.position
        line, size = self.course.line, self.course.size
        # Keep the nearest-point search on the current stretch, even when
        # another part of the circuit is physically close.
        nearby = np.arange(self.index - 12, self.index + 27) % size
        self.index = int(nearby[np.argmin(np.sum((line[nearby] - position)**2, axis=1))])
        aim = (self.index + max(3, round(speed * STEERING_LOOKAHEAD / SAMPLE_SPACING))) % size
        tangent = line[(aim + 4) % size] - line[(aim - 4) % size]
        tangent /= np.linalg.norm(tangent)
        normal = np.array([-tangent[1], tangent[0]])
        lane = 0 if airborne or self.course.lining_up_for_pad(self.index) else self.passing_lane(
            obs, line[aim], tangent, normal)
        self.lane += np.clip(lane - self.lane, -2.3, 2.3)

        desired_heading = heading(line[aim] + normal * self.lane - position)
        facing, momentum = obs.facing, obs.momentum
        velocity = np.array([sin(momentum), -cos(momentum)]) * speed
        if obs.windy and speed > 2 and not dashing and not airborne:
            velocity = obs.velocity
            # Wind changes the direction of travel without rotating the car.
            # Aim upwind by the observed difference between those directions.
            drift = angle_error(heading(velocity) - momentum)
            desired_heading -= WIND_COMPENSATION * np.clip(drift, -0.4, 0.4)
        error = angle_error(desired_heading - facing)
        steer = error - 0.1 * angle_error(momentum - facing) - STEERING_DAMPING * obs.turn_rate
        if obs.spinning:
            steer = 0.5 if obs.spinning > 0 else -0.5
        self.debug = dict(aim=aim, desired=desired_heading, facing=facing, momentum=momentum,
                          error=error, steer=steer, turn_rate=obs.turn_rate)

        buttons = []
        if abs(steer) > 0.018:
            buttons.append('RIGHT' if steer > 0 else 'LEFT')
            if not airborne and abs(error) > 0.24:
                buttons.append('LEAN_RIGHT' if steer > 0 else 'LEAN_LEFT')

        # Brake for upcoming bends, or if a slide would carry us off the road.
        sliding_wide = (not airborne and speed > 5.1 and
                        abs(angle_error(momentum - desired_heading)) > 0.20 and
                        any(not self.course.is_road(position + velocity * frames)
                            for frames in (7, 11)))
        braking_for_bend = speed > self.course.entry_speed[self.index] + 0.12
        if not airborne and (braking_for_bend or sliding_wide):
            buttons.append('BRAKE')
            self.stats.brake_frames += 1
            if braking_for_bend and speed <= self.course.corner_speed[self.index]:
                self.stats.approach_brake_frames += 1
        else:
            buttons.append('GAS')
        if airborne:
            height, vertical_speed = obs.height, obs.vertical_speed
            # Estimate the distance to a soft landing. A bend with too little
            # runway calls for a brief dive followed by a nose-up touchdown.
            flight = (vertical_speed + sqrt(vertical_speed**2 + 2 * NOSE_UP_GRAVITY * height))
            flight /= NOSE_UP_GRAVITY
            dive = (height > 0xA00 and vertical_speed > -500 and
                    (flight + LANDING_MARGIN) * speed > self.course.airborne_runway(self.index, speed))
            buttons.append('NOSE_DOWN' if dive else 'NOSE_UP')

        use_boost = (self.course.boost_window[self.index] and obs.boosts and
                     not obs.boost_blocked and not self.boost_pressed)
        if use_boost:
            buttons.append('BOOST')
        self.boost_pressed = bool(use_boost)
        return tuple(buttons)

    def summary(self):
        return asdict(self.stats)

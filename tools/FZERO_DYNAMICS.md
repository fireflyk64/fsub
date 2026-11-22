# fsub's driving: F-Zero's numbers, the driver's car

fsub's speeds, acceleration, brakes, grip, dirt and jumps are SNES F-Zero's, with the Blue
Falcon's tables read from the game. The handling is fsub's own.

For a day it was all F-Zero's, so that one bot could drive both games: the SNES F-Zero bot's
policy (`tools/racing/policy.py`) raced fsub unchanged, 1st, 2nd, 2nd, 2nd (commit 870711e).
But people playing it found the corners threw them about. So the car is now the driver's: a
bend never turns it, and instead its edges pay.

## Where the numbers come from

* **The ROM.** The Blue Falcon's tables, read out of the SNES ROM (LoROM, a 512-byte header):
  acceleration `$02:CA37`, brakes `$02:CA96`, turn factors `$02:C9AB` and `$02:C9F7`.
  `tools/gen_physics.py` holds them and builds fsub's tables from them (`build/physics.inc`).
* **F-Zero Forever** (a C port of the game's movement), for the shape of the model: the turn
  stage, grip, the wall, dirt and the jump.
* **Race logs.** The SNES bot's Mute City I and II races, logged every frame (speed, facing,
  momentum, turn rate, height), check the model against the game:
  * the turn builds from 0.34 to 1.36 steps a frame over 13 frames;
  * the turn dies away from a lean in 16 frames;
  * reversing from full lock, the turn takes about 10 frames to cross zero;
  * a jump at 7.5 lasts about 82 frames;
  * the road is 258 units wide at the median, and the tightest bend has a radius of 95.
* **A wall probe.** The Blue Falcon driven into Mute City I's wall: the part of its velocity
  into the wall reverses. (F-Zero Forever has no bounce; the game does.)

F-Zero's top speed, 8.81 units a frame, is fsub's 8: every length and speed is F-Zero's times
S = 8 / 8.81 = 0.908. Angles are F-Zero's (192 steps to a turn).

## The model

| | F-Zero | fsub |
|---|---|---|
| acceleration | the ROM's table: strong from rest, a trickle near the top | the same × S, × the car's |
| brakes | about 14/256 a frame near the top | the same × S, half while steering; braking through a bend charges a boost (below) |
| coasting | 4/256 a frame | the same × S |
| turn stage | builds to ±14 (±16 leaning) at 1/frame growing 0x1E/frame; fades 1/frame | builds at 2/frame growing 0x40/frame; fades 4/frame; turned the other way, straight at once |
| facing | stage × turn factor(speed) / 2 a frame | the same × the car's turning (eighths); no more than 12 steps (22°) off the road; let go and it straightens by an eighth a frame |
| the road in a bend | turns under the car (2D) | does not turn the car: it holds its line round |
| momentum (where it goes) | follows the facing at the grip rate, only with gas or steering held (else a drift) | follows the facing at the grip rate, always |
| grip | 0x180 within 30 steps; 0xA0 sliding or in the air; 0x20 on dirt; 0x280 below 5.5 | the same (each car its own) |
| across the road | speed × sin(slide) | three quarters of that: drawn 168 wide, it drives as wide as F-Zero's road |
| distance | where it goes | speed × cos(slide), × R / (R − x) on the inside of a bend: the short way round |
| the outside of a bend | (the long way round) | banked: the car may go up to (x − 12) × \|T\| / 2 256ths over its top, pulled up 20/256 a frame, and it carries the speed out |
| the wall | bounce: the velocity into it reverses; 10 frames without control | a glance: a quarter of the angle, the other way, turned along the road; a wheel turned into it straightened; a hard hit (4 steps) 5 frames without control; 5/64 health a knock, not again for 9 frames |
| dirt | top speed 3.0; turning halved | the same × S |
| jump | up at speed / 2, 1 to 4.5 a frame; falls 25/256 a frame (much faster nose down) | the same × S |

## Why each departure

* **The road does not turn the car; the car straightens when let go; the turn is quicker.**
  * In F-Zero's model a bend turns the road under the car. A car not turned to follow it
    drifts wide, and the turn winds up and carries on for 16 frames after the d-pad.
  * On fsub's screen that read as being thrown around. The user's words: "the way the
    turns kinda throw you around isn't fun".
* **The edges of a bend pay instead.** The user asked that "the curves give you basically just
  speed boosts if you're hugging inside or outside".
  * The inside is the short way round.
  * The outside is banked: faster than top speed, carried out of the bend.
  * The middle gets neither.
  * The extreme lines run past the outer rival lanes' barriers, and the pads sit near the
    middle: a choice of lines.
  * Laps by line, no rivals (middle / inside / outside):

    | Track | Middle | Inside | Outside |
    |---|---:|---:|---:|
    | Neo City | 33.1 s | 31.7 s | 33.2 s |
    | Blue Deep | 31.6 s | 32.1 s | 31.8 s |
    | Gold Wind | 38.0 s | 37.5 s | 37.4 s |
    | Old Port | 33.8 s | 32.3 s | 32.0 s |

    These are a scripted driver's laps; a person who times the edges does better.
* **Across at three quarters, and the glancing rail.** F-Zero's full rebound on fsub's
  narrower road "bounced back and forth like a ping pong ball", then the car blew up.
  * A person-like driver probe: it hits the rail at any angle, reacts 0.2 s later. It now
    takes one knock and never crosses the middle.
* **Braking into a bend pays.** With nothing to slow for, braking had no point. The user:
  "breaking for turns should be rewarded somehow".
  * Braking through a bend (on the ground, above speed 4) charges a boost: a frame of charge a
    frame, two in a hairpin, at most 30.
  * Let go of the brake and it goes off: half a frame of boost per frame of charge, with the
    boost's surge, flash and sound. Under 8 frames of charge fizzles.
  * Brake too long and you only lose the speed. Laps by line and brake-in, no rivals:

    | Track | Middle | Brake 10 | Brake 20 | Brake 40 | Inside | Inside, brake 15 |
    |---|---:|---:|---:|---:|---:|---:|
    | Neo City | 33.2 s | 32.3 s | 32.2 s | 33.9 s | 31.7 s | 30.3 s |
    | Blue Deep | 31.6 s | 31.3 s | 31.0 s | 31.6 s | 32.2 s | 31.3 s |
    | Gold Wind | 37.9 s | 36.9 s | 36.6 s | 37.4 s | 37.6 s | 35.9 s |
    | Old Port | 33.8 s | 32.6 s | 32.1 s | 33.9 s | 32.3 s | 29.6 s |

  * At a full frame of boost per frame of charge it was worth up to 4 s a lap: too much.
  * The brake always brakes now. F-Zero's lean (gas + brake + steer, no braking) is gone; it
    would have charged for free.
* **Rivals.** They hold their straight pace (8.3) through a bend, and a little more (+0.7)
  for a good line.
  * Following the guide a person's reaction late (`playtest.js guided`: it brakes in when the
    guide says, and lets go when it says):

    | Level | Neo City | Blue Deep | Gold Wind | Old Port |
    |---|---|---|---|---|
    | NORMAL | 1st | 2nd | 2nd | 1st |
    | HARD | 1st | 2nd | 3rd | 1st |
    | EXPERT | 1st | ranked out | ranked out | 3rd |

## What the courses had to change (for F-Zero's model, and kept)

* **No corner is tighter than F-Zero's tightest** (level 16). The sharper ones are spread over
  more chunks.
* **Patches act where they are drawn.** Dirt, pads, recharge strips and ramps sit 18 units
  either side of the line, and act 24 units either side of that.
  * They used to act over the whole half of the road, while drawn near the rail.
* **A ramp's flight is long:** about 3.5 chunks at a boost's speed.

## The bot

`tools/racing/policy.py` is the SNES bot's driving logic. `tools/fzero_snes/driver.py` adapts
it to SNES F-Zero: a Mute City I race through it matches the original frame for frame.
`tools/fsub_bot/run.py` adapts it to fsub (PyBoy): fsub's course in F-Zero units, from the
chunks' bends, laid out as the race's laps end to end.

It still drives fsub's races. But it brakes by F-Zero's turning, before a bend rather than
through it, so it is no longer the yardstick. At NORMAL: Neo City 4th; the others ranked out. To have it race fsub well again, either:
* teach the policy that a bend needs no slowing (a flag the fsub adapter passes); or
* bring F-Zero's handling back as a menu option (commit 870711e has it).

## What it costs

The physics is about 3–4 lines of CPU a frame more than fsub's first. Drive runs first in the
frame, so every cycle it adds pushes the rest (the rivals, the road's objects, the music) into
the part of the frame where the line interrupt takes half of each line. And rivals that no
longer slow for bends keep the pack together, so frames with all seven on screen (the dearest)
are common.

That alone left the frame in time: it was handed to VBlank with lines to spare. What dropped
frames was the main loop. It cleared its "VBlank happened" flag at the top. So when the
music driver (which runs after the frame is handed over) spilled a few lines past VBlank, the
loop slept a whole frame more: a stutter. Fixed (MainLoop takes the flag where it uses it): a
tail that runs a little late now costs nothing.

And these give back headroom:
* **The status bar.** It was rebuilt every 16 frames for a blink that was not showing; now it
  blinks only when it can. It is rebuilt after the frame is handed over, and put off a frame
  or two when late.
* **The boost's sky flash.** It rewrote the sky every frame for 8 frames; now only when its
  colours change (white, grey, back), with the copy unrolled.
* **Cached multiplies.** The physics' multiplies are kept with their inputs (the bend and lane
  for the inside's factor and the bank, the lock and speed for the turn, the angle and speed
  for the step across), and not redone when those have not changed.
* **The arithmetic.** An 8-by-8 multiply by quarter squares (a 1 KB table built at boot); the
  car's tables built when the car is chosen; the physics tables in RAM (the D000 bank, copied
  at boot: ROM0 is full), on page boundaries.

`playtest.js` counts both kinds of drop:
* `drops`: the frame counter skipped.
* `repeats`: a picture shown twice, its frame having missed VBlank.

`DROPS=1` says what was going on at each.

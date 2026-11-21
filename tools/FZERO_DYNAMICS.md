# fsub drives like SNES F-Zero

fsub's driving is SNES F-Zero's, its numbers and all, so that one bot drives both games:
the SNES F-Zero bot's policy (`tools/racing/policy.py`) races fsub unchanged, through an
adapter that only converts units (`tools/fsub_bot/run.py`).

## Where the numbers come from

* **The ROM.** The Blue Falcon's tables, read out of the SNES ROM (LoROM, a 512-byte header):
  acceleration `$02:CA37`, brakes `$02:CA96`, turn factors `$02:C9AB` and `$02:C9F7`.
  `tools/gen_physics.py` holds them and builds fsub's tables from them (`build/physics.inc`).
* **F-Zero Forever** (a C port of the game's movement), for the shape of the model: the turn
  stage, grip, the wall, dirt and the jump.
* **Race logs.** The SNES bot's Mute City I and II races, logged every frame (speed, facing,
  momentum, turn rate, height), check the model against the game:
  * the turn builds from 0.34 to 1.36 steps a frame over 13 frames;
  * the turn dies away from a lean in 16 frames, falling 22/256 a frame;
  * a jump at 7.5 lasts about 82 frames;
  * the road is 258 units wide at the median;
  * the tightest bend has a radius of 95 units.
* **A wall probe.** The Blue Falcon driven into Mute City I's wall shows the bounce: the part
  of its velocity into the wall reverses, its facing stays, and it loses speed for a few
  frames after. (F-Zero Forever has no bounce; the game does.)

## The scale

F-Zero's top speed, 8.81 units a frame, is fsub's 8. So every length and speed is F-Zero's
times S = 8 / 8.81 = 0.908. Angles are F-Zero's own (192 steps to a turn), and frames are
frames, so every angular rate is F-Zero's as it is.

## The model (fsub = F-Zero x S)

| | F-Zero | fsub |
|---|---|---|
| turn stage | ±14 steps at full lock, ±16 leaning (L/R); builds at 1/frame, growing 0x1E/frame; fades 1/frame | the same. Leaning is brake + steer at speed. With the gas held too it leans without braking |
| facing turns | stage × turn factor(speed) / 2, in 256ths of a step a frame | the same, × the car's turning (eighths) |
| momentum (where it goes) | follows the facing at the grip rate, only with gas or steering held: otherwise it drifts | the same |
| grip | 0x180 within 30 steps of slide; 0xA0 sliding or in the air; 0x20 on dirt; 0x280 below 5.5 | the same (each car its own normal grip) |
| the road | 2D | turns under the car by its true curvature: a level-L corner turns L × 90 / 16 degrees in a 256-unit chunk |
| distance | where it goes | speed × cos(slide) × R / (R − x): the inside of a bend is the short way |
| acceleration | the ROM's table: strong from rest, a trickle near the top | the same, × S, × the car's |
| brakes | about 14/256 a frame near the top | the same × S |
| coasting | 4/256 a frame | the same × S |
| the wall | bounce: the velocity into it reverses; 10 frames without control; 192/2048 of the energy every 9 frames in contact; −0x10 speed a frame above 4 | the same (5/64 health a knock) |
| dirt | top speed 3.0; turning halved | the same × S |
| jump | up at speed / 2, 1 to 4.5 a frame; falls 25/256 a frame (much faster nose down); a hard landing bounces unless the nose is up | the same × S |

## What the courses had to change

* **The road is F-Zero's width.** Its half width is 84 units (F-Zero's 258 to a top speed of
  8.81, scaled). Rival lanes are at ±18 and ±54.
* **No corner is tighter than F-Zero's tightest.** fsub corners are level 8 or 16: a radius of
  326 or 163 units (360 or 180 of F-Zero's). The level-24 and level-32 corners (radius 109
  and 81) were tighter than anything in F-Zero. Each is now spread over more chunks: the same
  turn, over a longer stretch.
  * A level-16 bend is taken at about 6.4 (7.3 leaning).
  * A level-8 bend is taken flat out.
* **Patches act where they are drawn.** Dirt, pads, recharge strips and ramps sit 18 units
  either side of the line, and act 24 units either side of that: just where the sprites are.
  * They used to act over the whole half of the road, while being drawn as a 47-unit patch
    near the rail. So the car was dragged by dirt it could see it had missed.
  * Meanwhile the middle six units of the road touched nothing.
  * Now the middle of the road crosses them, as F-Zero's line crosses its dirt and plates.
* **The rivals' pace is the physics'.** In a corner the best rival runs as fast as the car
  can turn to follow it, and on the straight it runs at 7.9: just under a top speed the car
  only creeps up to.
* **A ramp's flight is long.** At a boost's speed it lasts about 3.5 chunks. A bend where it
  lands calls for the nose down, as on Mute City II.

## The bot, in both games

`tools/racing/policy.py` is the SNES bot's driving logic, lifted out of
`tools/fzero_snes/driver.py` unchanged. The SNES side is now a thin adapter:
* a Mute City I race re-run through it matches the original frame for frame (9562 frames,
  every button and position);
* it was re-checked after the last change to the policy.

fsub's adapter:
* **The course.** It builds fsub's course in F-Zero units from the chunks' bends (with their
  true curvature), laid out as the race's laps end to end. A lap turns 360 degrees but need
  not close, so nothing is bent to make it meet itself.
* **Surfaces.** It answers the policy's surface lookups from fsub's things. A barrier counts
  as off the road.
* **The car.** It reports the car's state (position, facing, momentum, turn rate, height),
  and the rivals' positions.
* **Buttons.** It presses fsub's buttons for the policy's controls:

  | Control | Button |
  |---|---|
  | gas | B |
  | brake, lean | A |
  | boost, nose down | Up |
  | nose up | Down |

`.venv/bin/python tools/fsub_bot/run.py --track N [--car N] [--level N]`, at NORMAL:

| fsub | Place | Health left | Jumps | Dirt frames | Rail frames | Peak load |
|---|---:|---:|---:|---:|---:|---:|
| Neo City | 1st | 64 | 3 | 0 | 0 | 91% |
| Blue Deep | 2nd | 62 | 3 | 29 | 0 | 91% |
| Gold Wind | 2nd | 64 | (no ramp) | 87 | 0 | 96% |
| Old Port | 2nd | 48 | 3 | 0 | 0 | 90% |

SNES F-Zero, the same policy (BOT.md): Mute City I 1st, Mute City II 2nd, Death Wind I 2nd.

By car, on Neo City and Old Port:
* HORNET: 1st and 2nd.
* BISON: 2nd and 3rd.
* COMET: 4th; ranked out on Old Port. It is the fastest car, slow to get there, and it slides;
  the bot plans its corners for ARROW.

At EASY on Old Port it is 1st; at HARD, 3rd.

## What it costs

The new physics is more arithmetic every frame, and every cycle spent early in the frame
pushes the rest into the part of it where the line interrupt takes half of each line. These
keep it close to the old cost:

* an 8-by-8 multiply by quarter squares, from a 1 KB table built in the D000 bank at boot
  (about 45 cycles, against 120 for the loop it replaces);
* the car's acceleration and turning tables, built once when the car is chosen;
* tables on page boundaries;
* skipping the work that does nothing on a straight, or for a car going where it points.

With the bot driving, mean load is 63–67% and the peak is 90–96%, with no dropped frames. The
old ROM ran at 59–60%. `PEAK=1 node tools/playtest.js expert` still finds a frame of 152 lines
on Neo City's last corner: two pads in play, and a corner in sight.

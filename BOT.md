# SNES F-Zero bot

The bot drives the Blue Falcon in Beginner Grand Prix. It reads the game's race state once per emulator frame and decides which SNES buttons to hold. The controller is rule-based, so the same ROM, emulator and inputs give a repeatable baseline for studying racing behavior.

## Run it

Create a Python virtual environment, install `stable-retro==1.0.1`, and put your F-Zero ROM at `fzero.smc` or supply it with `--rom PATH`.

```sh
.venv/bin/python tools/fzero_snes/run.py --track mute-city-i
.venv/bin/python tools/fzero_snes/run.py --track mute-city-ii
.venv/bin/python tools/fzero_snes/run.py --track death-wind-i
```

Mute City I opens Knight League, and Mute City II opens Queen League. Death Wind I is the fourth Knight League race. The bot qualifies on Mute City I, Big Blue and Sand Ocean and advances through the results screens with Start. Each race gets a fresh plan from the track data the game loads. The runner goes through the normal menus from power-on using controller inputs.

## How it drives

1. **Build the racing line.** The game loads ordered checkpoints and a map of the track's surface tiles into work RAM. The bot joins the checkpoints, samples the line at roughly eight world units per point and smooths the joins. Where that line crosses a series of dirt strips, it looks for a clean lane past the whole section and eases in and out of it. During the race it searches near its last position on the line, so a hairpin with two nearby lanes doesn't cause it to jump to the other leg.
2. **Brake while there is still room.** The change in heading along the line gives an estimate of the bend's curvature. Tighter sections get a lower speed limit. The bot works that limit backward along the approach using `entry_speed² = corner_speed² + 2 × deceleration × distance`. When the car is above the resulting entry speed it presses Y. It also brakes when its motion would carry it wide onto a bad surface.
3. **Steer toward where the car needs to go.** The steering target sits farther ahead at higher speeds. The controller uses both facing and momentum and accounts for the rotation that continues after releasing the D-pad. It adds L or R for sharper turns and countersteers after a hit starts a spin. Damping matters because correcting every small error at full steering can send the car from one edge of the track to the other.
4. **Give traffic room.** The bot scores the center line and two passing offsets against nearby cars. It samples upcoming road tiles at each offset and rejects lanes that would lead onto dirt or off the road. It eases into the chosen offset to keep the steering target steady.
5. **Use the track surfaces.** The line goes through the jump plates on both Mute City courses. The bot stays on that line near a plate and pitches the nose up to land smoothly. If a bend is close, as on Mute City II, it estimates the remaining flight from height and vertical speed and can briefly pitch down to shorten the jump. It looks for dash plates along the same line on Death Wind I and uses the difference between momentum and measured travel to counter wind on wind tiles. It saves the lap boost for a stretch with room to run at boost speed.

The policy and work-RAM offsets live in the driver. The runner handles menus, qualifying races, recording and replay. [Driver](tools/fzero_snes/driver.py) · [Runner](tools/fzero_snes/run.py) · [F-Zero RAM map](https://sneslab.net/wiki/F-Zero_RAM_Map) · [F-Zero Forever surface and movement lookup](https://github.com/RetroPortingToolKit/F-ZeroForever/blob/main/src/fzero_actor.c)

## Verify and replay a run

These runs completed all five laps from power-on with the local ROM and Stable Retro 1.0.1.

| Course | Finish | Approach brake frames | Jump plate hits | Dash plate hits | Dirt frames |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mute City I | 1st | 232 | 5 | 0 | 0 |
| Mute City II | 2nd | 222 | 10 | 0 | 80 |
| Death Wind I | 2nd | 83 | 0 | 15 | 3 |

The Death Wind I run qualified in first on Mute City I and Big Blue, then second on Sand Ocean. The Mute City II replay reproduced the finishing rank and final screen hash.

```sh
.venv/bin/python tools/fzero_snes/run.py --track mute-city-ii \
  --output result.json --record-inputs inputs.json
.venv/bin/python tools/fzero_snes/run.py --inputs inputs.json --output replay.json
```

Check that `track` matches `target_track`, `outcome` is `finished`, and `laps_completed` is five. `place` is the game's rank. `podium` is true for any qualifying top-three Grand Prix finish. The Death Wind I report includes the earlier races in `qualifying_races`. The top-level frame count covers the entire run from power-on.

- `brake_frames` counts frames with Y applied. `approach_brake_frames` counts the subset where the upcoming bend forced braking ahead of its local speed limit.
- `jump_pad_hits` and `dash_pad_hits` count game-state transitions triggered by the respective plates. `dirt_frames` counts grounded frames on dirt, so a single excursion can span many frames.
- Compare the ROM hash, outcome, place and final screen hash when replaying. Replays run the recorded buttons and report the final frame. Driving counters come from the live policy run.

## The same bot and Fsub

The policy lives in [tools/racing/policy.py](tools/racing/policy.py), shared by both games. Each game has a thin adapter:

- **SNES:** [driver.py](tools/fzero_snes/driver.py) reads work RAM and presses SNES buttons. A Mute City I race through it matches the original frame for frame.
- **Fsub:** [tools/fsub_bot/run.py](tools/fsub_bot/run.py) runs the ROM in PyBoy. It converts Fsub's state to F-Zero units and presses Fsub's buttons.

For one version (Fsub commit 870711e), Fsub's driving was F-Zero's, and this policy raced it unchanged: 1st, 2nd, 2nd, 2nd at NORMAL. Players found the corners threw them around, so Fsub's handling is now its own: a bend no longer turns the car, and hugging its inside or outside pays instead. The policy still finishes Fsub's races, but it brakes for bends that no longer need it, so it falls back (5th and 3rd, and ranked out twice). [tools/FZERO_DYNAMICS.md](tools/FZERO_DYNAMICS.md) has the model, what changed, and why.

```sh
.venv/bin/python -m pip install pyboy
.venv/bin/python tools/fsub_bot/run.py --track 0      # 0 Neo City, 1 Blue Deep, 2 Gold Wind, 3 Old Port
```

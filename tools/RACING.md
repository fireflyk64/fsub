# Headless Fsub playtest

Build the ROM with `make`, then run `node tools/playtest.js masher --track 0 --level 0`. Track 0 is Mute City; level 0 disables rivals. The masher policy steers toward the middle while holding the throttle.

`RECORD_INPUTS=inputs.json RESULT_JSON=result.json node tools/playtest.js masher --track 0 --level 0` records the buttons held at each emulated frame and the outcome. Replay with `REPLAY_INPUTS=inputs.json RESULT_JSON=replay.json node tools/playtest.js masher --track 0 --level 0`. Use the same ROM, symbols, and options when replaying: menu configuration may write game memory directly. A replay that runs out of input fails. The outcome is written at the end; check `wrecked`, `rankedOut`, and `place`, rather than assuming every run finishes. Use one bot per recording.

# SNES F-Zero integration

Create an environment with `python3 -m venv .venv` and install `stable-retro==1.0.1` into it. Put your F-Zero ROM at `fzero.smc` or pass `--rom PATH`. To drive Mute City I in Knight League on Beginner with the Blue Falcon, run

```sh
.venv/bin/python tools/fzero_snes/run.py --output result.json
```

Pass `--track mute-city-ii` for the Queen League opener or `--track death-wind-i` to qualify through the first three Knight League races and drive Death Wind I. The controller, course behavior and race metrics are documented in [BOT.md](../BOT.md).

Use `--record-inputs inputs.json` to capture the run. Pass that file back with `--inputs inputs.json` to replay the controller inputs from power-on. Run the existing straight-throttle smoke test with

```sh
.venv/bin/python tools/fzero_snes/run.py --inputs tools/fzero_snes/mute_city_straight.json --output result.json
```

Input files contain button holds measured in emulator frames. Bot mode stops at the race outcome or at its frame limit. Replay mode runs the full sequence and reports the final frame. The runner starts from fresh save RAM. Use the same ROM, emulator version and input sequence when reproducing a run, and compare the ROM and screen hashes in the result.

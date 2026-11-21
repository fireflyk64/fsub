#!/usr/bin/env python3
"""Race F-Zero on SNES or replay controller inputs from power-on."""
import argparse
import hashlib
import itertools
import json
import pathlib
import tempfile

import numpy as np
import stable_retro as retro

from driver import Driver, LAP, PLACE, RACE_ENDED, RACE_STATE

ROOT = pathlib.Path(__file__).resolve().parent
WORK_RAM = 0x7E0000
GAME_MODE = 0x54
RACE_MODE = 2
PRACTICE_FLAG = 0x58
LEAGUE = 0x90
RACE_NUMBER = 0x53
KNIGHT, QUEEN = 0, 1
LEAGUE_COURSES = {
    KNIGHT: ('mute-city-i', 'big-blue', 'sand-ocean', 'death-wind-i', 'silence'),
    QUEEN: ('mute-city-ii',),
}
TRACKS = {
    'mute-city-i': (KNIGHT, 0),
    'death-wind-i': (KNIGHT, 3),
    'mute-city-ii': (QUEEN, 0),
}


def start_grand_prix(league):
    # Title screen, Grand Prix and the default Blue Falcon.
    for count, buttons in ((180, ()), (1, ('START',)), (40, ()), (1, ('START',)),
                           (60, ()), (1, ('A',)), (60, ()), (1, ('A',))):
        yield from itertools.repeat(buttons, count)
    if league == QUEEN:
        yield from itertools.repeat((), 90)
        yield ('DOWN',)
        yield from itertools.repeat((), 29)
    else:
        yield from itertools.repeat((), 120)
    # Confirm the league and Beginner class, then let the grid intro play.
    for count, buttons in ((1, ('A',)), (200, ()), (1, ('B',)), (150, ()),
                           (1, ('B',)), (250, ())):
        yield from itertools.repeat(buttons, count)


def replay_actions(path, available_buttons):
    for segment in json.loads(path.read_text()):
        count = segment['frames']
        buttons = tuple(segment['buttons'])
        if type(count) is not int or count < 0:
            raise ValueError('frames must be a nonnegative integer')
        unknown = set(buttons) - set(available_buttons)
        if unknown:
            raise ValueError(f'Unknown buttons {sorted(unknown)}. Available buttons are {available_buttons}')
        yield from itertools.repeat(buttons, count)


def at_grid(ram, league, race):
    return (ram[GAME_MODE:GAME_MODE + 3] == b'\x02\x02\x02' and
            ram[LEAGUE] == league and ram[RACE_NUMBER] == race and
            not any(ram[address] for address in (0x52, 0x57, PRACTICE_FLAG, 0x5B)))


def advance_to_grid(env, league, race):
    # Tap Start through the finish presentation and results screens.
    for frame in range(2000):
        yield ('START',) if frame % 20 == 0 else ()
        if at_grid(env.data.memory.blocks[WORK_RAM], league, race):
            yield from itertools.repeat((), 20)
            return
    raise ValueError(f'Timed out advancing to {LEAGUE_COURSES[league][race]}')


def bot_actions(env, track, max_frames):
    league, target_race = TRACKS[track]
    yield from start_grand_prix(league)
    qualifying = []
    for race in range(target_race + 1):
        ram = env.data.memory.blocks[WORK_RAM]
        if not at_grid(ram, league, race):
            raise ValueError(f'Expected the Blue Falcon countdown on {LEAGUE_COURSES[league][race]}')

        driver = Driver(ram)
        for _ in range(max_frames):
            if ram[RACE_STATE] & RACE_ENDED:
                break
            yield driver.buttons(ram)
            ram = env.data.memory.blocks[WORK_RAM]
        driving = driver.summary()
        result = race_result(ram, timed=True)
        if race == target_race or not result['podium']:
            return driving, qualifying
        qualifying.append({**result, 'driving': driving})
        yield from advance_to_grid(env, league, race + 1)


def race_result(ram, timed):
    state = ram[RACE_STATE]
    if state & 0x80:
        outcome = 'lost'
    elif state & 0x40:
        outcome = 'exploded'
    elif state & 0x20:
        outcome = 'finished'
    else:
        outcome = 'timeout' if timed else 'ongoing'
    racing = ram[GAME_MODE] == RACE_MODE
    place = (ram[PLACE] or None) if racing else None
    laps = ram[LAP] if racing and ram[LAP] <= 5 else 0
    grand_prix = racing and not ram[PRACTICE_FLAG]
    courses = LEAGUE_COURSES.get(ram[LEAGUE], ())
    race = ram[RACE_NUMBER]
    track = courses[race] if grand_prix and race < len(courses) else None
    return {
        'track': track,
        'outcome': outcome,
        'place': place,
        'laps_completed': laps,
        'podium': outcome == 'finished' and grand_prix and place in (1, 2, 3),
    }


def run(env, args):
    observation, info = env.reset()
    if args.inputs:
        actions = replay_actions(args.inputs, env.buttons)
    else:
        actions = bot_actions(env, args.track, args.max_frames)

    frames = 0
    masks = {}
    recording = []
    while True:
        try:
            buttons = next(actions)
        except StopIteration as finished:
            bot_result = finished.value
            break
        if buttons not in masks:
            masks[buttons] = np.array([b in buttons for b in env.buttons], dtype=np.int8)
        observation, _, _, _, info = env.step(masks[buttons])
        frames += 1
        if args.record_inputs:
            if recording and recording[-1]['buttons'] == buttons:
                recording[-1]['frames'] += 1
            else:
                recording.append({'frames': 1, 'buttons': buttons})
    if args.record_inputs:
        args.record_inputs.write_text(json.dumps(recording, indent=2) + '\n')

    ram = env.data.memory.blocks[WORK_RAM]
    result = {
        **race_result(ram, timed=not args.inputs),
        'frames': frames,
        'rom_sha256': hashlib.sha256(args.rom.read_bytes()).hexdigest(),
        'buttons': env.buttons,
        'info': info,
        'screen_sha256': hashlib.sha256(observation.tobytes()).hexdigest(),
    }
    if bot_result is not None:
        driving, qualifying = bot_result
        result['target_track'] = args.track
        result['driving'] = driving
        if qualifying:
            result['qualifying_races'] = qualifying
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rom', type=pathlib.Path, default=ROOT.parent.parent / 'fzero.smc')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--track', choices=TRACKS, default='mute-city-i',
                      help='target course in Grand Prix (default: mute-city-i)')
    mode.add_argument('--inputs', type=pathlib.Path,
                      help='replay a JSON list of {"frames": number, "buttons": [button, ...]}')
    parser.add_argument('--max-frames', type=int, default=15000,
                        help='frame limit per race in bot mode (default: 15000)')
    parser.add_argument('--record-inputs', type=pathlib.Path, help='save controller inputs for replay')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    if args.max_frames < 1:
        parser.error('--max-frames must be positive')

    with tempfile.TemporaryDirectory(prefix='fzero-retro-') as tmp:
        integration = pathlib.Path(tmp) / 'FZero-Snes'
        integration.mkdir()
        for name in ('metadata.json', 'data.json', 'scenario.json'):
            (integration / name).symlink_to(ROOT / 'FZero-Snes' / name)
        (integration / 'rom.sfc').symlink_to(args.rom.resolve())
        retro.data.add_custom_integration(tmp)
        env = retro.make('FZero-Snes', state=retro.State.NONE,
                         use_restricted_actions=retro.Actions.ALL, render_mode='rgb_array')
        try:
            result = run(env, args)
        finally:
            env.close()

    report = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(report)
    else:
        print(report, end='')


if __name__ == '__main__':
    main()

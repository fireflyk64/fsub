// Playtest bots: drive a full race in the ROM (headless, in the web build's emulator) at
// three levels of skill and report how each got on.  For tuning the balance.
//
//   node tools/playtest.js [masher|casual|expert ...] [--track N] [--level N] [--car N] [--mode N] [--gif NAME FROM TO]
//
// AFTER=N runs on N frames past the end of the race, hands off (the finale), and with --gif
// records those frames instead.  --car N picks the car (0 ARROW .. 3 COMET).
// PEAK=1 prints the frames that set a new worst load, with what was going on (PEAK=all:
// some fixed frames);
// LOADAVG=1 the mean load as well.
//
// masher  holds the throttle and steers for the middle of the road.  Nothing else.
// casual  also brakes when a sharp bend is already throwing it wide, dodges what it sees,
//         and fires boosts on straights.
// expert  knows the course: brakes before bends to the speed the physics allows, takes the
//         inside line, goes for boost pads, uses the tunnel, skid-turns when too fast.
// human   the expert with a person's reactions: it acts on what it saw REACT frames ago (0.3 s),
//         so it brakes and dodges that much late, and keeps a margin for it.  If the human
//         cannot get through without hitting things, a person cannot either.
// lifter  how a player of the old F-Zero drives: holds the gas, lifts off for a sharp corner
//         it can see coming, never brakes, steers for the inside, dodges (also 0.3 s late).
// guided  does what the page's guide (web/guide.js) says, and nothing else, REACT frames after
//         it says it: the check that following the guide gets you round.
const fs = require('fs'), vm = require('vm'), path = require('path');
const ROOT = path.join(__dirname, '..');
vm.runInThisContext(fs.readFileSync(ROOT + '/web/binjgb.js', 'utf8') + '\nglobalThis.Binjgb = Binjgb;');
const sym = {};
for (const l of fs.readFileSync(ROOT + '/fzero.sym', 'utf8').split('\n')) { const m = l.match(/^[0-9a-f]+:([0-9a-f]{4}) (\w+)$/i); if (m) sym[m[2]] = parseInt(m[1], 16); }
const args = process.argv.slice(2);
const KINDS = ['masher', 'casual', 'expert', 'human', 'lifter', 'guided'];
let advise = null;                               // web/guide.js's, for the guided bot
const bots = args.filter(a => KINDS.includes(a));
const REACT = +(process.env.REACT || 18);       // frames between seeing and acting, for human and lifter
const levelAt = args.indexOf('--level'), level = levelAt >= 0 ? +args[levelAt + 1] : -1;   // (-1: the menu's own; 0: no rivals)
const trackAt = args.indexOf('--track'), track = trackAt >= 0 ? +args[trackAt + 1] : 0;
const carAt = args.indexOf('--car'), car = carAt >= 0 ? +args[carAt + 1] : 0;   // (0 ARROW, 1 HORNET, 2 BISON, 3 COMET)
const modeAt = args.indexOf('--mode'), mode = modeAt >= 0 ? +args[modeAt + 1] : 0;   // (0 RACE, 3 LEARN: never ranked out)
const gifAt = args.indexOf('--gif');
const asmConst = name => +fs.readFileSync(ROOT + '/fzero.asm', 'utf8').match(new RegExp('DEF ' + name + ' +EQU +(\\d+)'))[1];
const asmConstOr = (name, dflt) => { const m = fs.readFileSync(ROOT + '/fzero.asm', 'utf8').match(new RegExp('DEF ' + name + ' +EQU +(\\d+)')); return m ? +m[1] : dflt; };
const PLAYER_Z = asmConst('PLAYER_Z');
const BRAKING = 13 / 256;                        // F-Zero's brakes near the top speed (BrakeTab): speed lost a frame

async function race(kind, record) {
  const wasm = fs.readFileSync(ROOT + '/web/binjgb.wasm');   // (instantiateWasm: newer Emscripten builds ignore wasmBinary)
  const m = await Binjgb({ instantiateWasm: (info, done) => { WebAssembly.instantiate(wasm, info).then((r) => done(r.instance)); return {}; } });
  const rom = fs.readFileSync(ROOT + '/fzero.gb'); const size = (rom.length + 0x7fff) & ~0x7fff;
  const ptr = m._malloc(size); new Uint8Array(m.HEAP8.buffer, ptr, size).fill(0).set(rom);
  const e = m._emulator_new_simple(ptr, size, 44100, 4096, 2); m._emulator_set_default_joypad_callback(e, m._joypad_new());
  const rd = a => m._emulator_read_mem(e, a), s8 = v => (v << 24) >> 24, s16 = v => (v << 16) >> 16;
  // The fastest the car follows a bend of level b: its turning at full lock (14 stage steps x its
  // turn table, the game's wTurnTab, / 4) against the road's turn under it (3b / 256 steps a unit).
  const limit = (b) => { if (Math.abs(b) < 3) return 12; for (let v = 12; v > 2; v -= 0.05) { if (14 * rd(sym.wTurnTab + Math.min(63, Math.floor(v * 4))) / 4 / 256 >= 3 * Math.abs(b) / 256 * v) return v; } return 2; };
  let lastFace = 0, lastX = 0;                    // (where the car pointed last frame, against the road, and where it was)
  const keys = {}; const set = (k, v) => { if (!!keys[k] !== !!v) { keys[k] = !!v; m['_set_joyp_' + k](e, v ? 1 : 0); } };
  const inputLog = []; const replay = process.env.REPLAY_INPUTS ? JSON.parse(fs.readFileSync(process.env.REPLAY_INPUTS, 'utf8')) : null;
  let ticks = 0; const step = () => {
    if (replay && inputLog.length >= replay.length) throw new Error('Input replay ended before the race finished');
    if (replay) { for (const k of ['up', 'down', 'left', 'right', 'start', 'select', 'A', 'B']) set(k, replay[inputLog.length].includes(k)); }
    inputLog.push(Object.keys(keys).filter(k => keys[k]));
    ticks += 70224; for (;;) { if (m._emulator_run_until_f64(e, ticks) & 4) break; } };
  // a chunk's bend (its true curvature: the top bit, "special tight", only changes the look)
  const felt = v => (v & 127) - 32;
  const bendAt = chunk => felt(rd(sym.wTrackBend + (chunk & 63)));
  const frames = [];
  const out = { kind, frames: 0, place: 0, health: 0, wrecked: false, hits: 0, minHealth: 64, dropped: 0, peak: 0, lapFrames: [], worst: 1, best: 8 };
  let lastHp = 64, lastLap = 1, lastF = -1, started = false, endAt = -1;
  const AFTER = +(process.env.AFTER || 0);
  const seen = [];                                // human, lifter: what they saw, frame by frame
  const told = [];                                // guided: what the guide said, frame by frame
  for (let i = 0; i < 40000; i++) {
    step();
    if (endAt >= 0) {                     // past the end: watch the finale
      if (i - endAt >= AFTER) break;
      for (const k in keys) set(k, 0);
      const f = rd(sym.hFrame); if (((f - lastF) & 255) !== 1) out.dropped++; lastF = f;
      if (record && (i - endAt) % 2 === 0) frames.push(Buffer.from(new Uint8Array(m.HEAP8.buffer, m._get_frame_buffer_ptr(e), 160 * 144 * 4)));
      continue;
    }
    const st = rd(sym.hState), lap = rd(sym.hLap), hp = rd(sym.hHealth), count = rd(sym.hCount);
    if (i > 20 && rd(sym.hMenu)) {        // the menu: pick the track and the level, then Start
      if (mode) m._emulator_write_mem(e, sym.hMode, mode);
      const row = rd(sym.wMenuRow), trk = rd(sym.hTrackNo), lv = rd(sym.hLevel), cr = rd(sym.wCar), tap = i % 6 < 3;
      let key = 'start';
      if (trk !== track) key = row !== 0 ? 'up' : (trk < track ? 'right' : 'left');
      else if (cr !== car) key = row !== 1 ? (row < 1 ? 'down' : 'up') : (cr < car ? 'right' : 'left');
      else if (level >= 0 && lv !== level) key = row !== 2 ? (row < 2 ? 'down' : 'up') : (lv < level ? 'right' : 'left');
      for (const k of ['up', 'down', 'left', 'right', 'start']) set(k, tap && k === key);
      continue; }
    if (!started) { for (const k of ['up', 'down', 'left', 'right', 'start']) set(k, 0); if (i > 40 && count > 0 && st === 0) { started = true; out.level = rd(sym.hLevel); } else continue; }
    const f = rd(sym.hFrame); if (lastF >= 0 && ((f - lastF) & 255) !== 1) { out.dropped++; if (process.env.DROPS) console.log("drop at frame", i, "race frame", out.frames, "state", st, "load line", rd(sym.hLoad), "fade", rd(sym.hFadeLevel)); } lastF = f;
    const ld = rd(sym.hLoad), lv = ld >= 144 ? ld - 144 : ld + 10;
    if (process.env.PEAK && (process.env.PEAK === 'all' ? [136, 396, 1000, 2000, 3000, 4000].includes(out.frames) : lv >= out.peak - 1)) console.log('peak', lv, 'frame', out.frames, 'chunk', ((rd(sym.hPos + 1) | rd(sym.hPos + 2) << 8) + PLAYER_Z) >> 8 & 63, 'state', st, 'count', count, 'hp', hp, 'air', rd(sym.hAir), 'objs', [0, 1].map(k => rd(sym.wObjSlots + k * 4) + ':' + rd(sym.wObjSlots + k * 4 + 1)).join(' '), 'flying', sym.wFlying === undefined ? '-' : rd(sym.wFlying), 'sfx', sym.wSfxPtr === undefined ? '-' : rd(sym.wSfxPtr + 1), 'flash', sym.wHitFlash === undefined ? '-' : rd(sym.wHitFlash), 'stale', rd(sym.hSkyStale), 'shown', [0,1,2,3,4,5,6].filter(r => rd(sym.wRivals + r * 8 + 7)).length);
    out.peak = Math.max(out.peak, lv); out.sum = (out.sum || 0) + lv; out.n = (out.n || 0) + 1;
    if (record && !AFTER && i >= record[0] && i < record[1] && i % 2 === 0) frames.push(Buffer.from(new Uint8Array(m.HEAP8.buffer, m._get_frame_buffer_ptr(e), 160 * 144 * 4)));
    if (hp < lastHp) { out.hits++; if (process.env.HITS) (out.where = out.where || []).push(((rd(sym.hPos + 2) & 63)) + ":" + (lastHp - hp)); } lastHp = hp; out.minHealth = Math.min(out.minHealth, hp);
    if (lap !== lastLap) { out.lapFrames.push(out.frames); lastLap = lap; }
    if (count === 0 && st === 0) { out.frames++; const r = rd(sym.hRank); if (out.frames > 600) { out.worst = Math.max(out.worst, r); out.best = Math.min(out.best, r); } }
    if (st !== 0) {
      out.place = rd(sym.hRank); out.health = hp; out.wrecked = st === 2; out.rankedOut = st === 3; out.lapFrames.push(out.frames);
      // how far each rival is ahead (+) or behind (-) at the end, in units
      out.gaps = []; for (let r = 0; r < 7; r++) out.gaps.push(s16(rd(sym.wRivals + r * 8 + 1) | rd(sym.wRivals + r * 8 + 2) << 8) - 175);
      if (!AFTER) break;
      endAt = i; continue;
    }
    // ---- the bot
    const x = s16(rd(sym.hX) | rd(sym.hX + 1) << 8) / 256, bend = rd(sym.hTarget) - 32, speed = (rd(sym.hSpeed) | rd(sym.hSpeed + 1) << 8) / 256;
    const face = s16(rd(sym.wFacing) | rd(sym.wFacing + 1) << 8) / 256;   // where the car points, against the road (steps)
    const pos = rd(sym.hPos + 1) | rd(sym.hPos + 2) << 8, chunk = (pos >> 8) & 63, boosts = rd(sym.hBoosts), air = rd(sym.hAir);
    let target = 0, gas = true, brake = false, boost = false, healing = false, steer = null, dive = false, noseUp = false;
    const objs = [];
    for (let k = 0; k < 2; k++) { const a = sym.wObjSlots + k * 4; if (rd(a)) objs.push({ kind: rd(a + 1), dist: ((rd(a + 2) | rd(a + 3) << 8) - pos) & 0xffff }); }
    // (human, lifter: the objects as they were REACT frames ago, moved on by how far we came)
    seen.push({ pos, objs: objs.map(o => ({ ...o })) }); if (seen.length > REACT + 1) seen.shift();
    const late = seen.length > REACT ? seen[0] : null;
    const lateObjs = late ? late.objs.map(o => ({ ...o, dist: (o.dist - ((pos - late.pos) & 0xffff)) & 0xffff })).filter(o => o.dist < 0x8000) : [];
    const dodge = (reach, list = objs) => { for (const o of list) { if (o.dist > reach) continue;
      if (o.kind === 0) { if (kind === 'expert') target = -36; else if (x < 0) target = 21; }       // tunnel mouth: left lane
      else if (o.kind <= 4) { const lane = [-54, -18, 18, 54][o.kind - 1]; const at = target || x;
        if (Math.abs(at - lane) < 22) target = (o.kind === 2 || o.kind === 3) ? (at < 0 ? -57 : 57) : (lane > 0 ? lane - 36 : lane + 36); }   // a middle lane: go to the wall on our side
      else if (o.kind <= 6) target = o.kind === 5 ? 40 : -40;                                       // dirt (18 either side of the line, 24 wide each way): off it
      else if (o.kind <= 8) { if (kind !== 'masher') target = o.kind === 7 ? -18 : 18; }            // boost pad: go to its middle
      else if (o.kind >= 11) { if (kind !== 'masher' && Math.abs(x - (o.kind === 11 ? -18 : 18)) < 30) target = o.kind === 11 ? 40 : -40; }   // a ramp: keep off it
      else if (kind !== 'masher' && rd(sym.hHealth) < 52) { target = o.kind === 9 ? -18 : 18; healing = true; } } };   // recharge patch: go to it if hurt
    if (kind === 'casual') {
      dodge(330);
      if (Math.abs(bend) > 16 && speed > 6.2 && Math.abs(x) > 20) brake = true;
      if (boosts && bend === 0 && bendAt(chunk + 1) === 0 && speed > 7.5) boost = true;
    } else if (kind === 'guided') {
      // What the guide said REACT frames ago: the pedals as it said, the place on the road it
      // pointed to (steered for as a person would, watching the car).
      told.push(advise(rd, sym)); if (told.length > REACT + 1) told.shift();
      const a = told.length > REACT ? told[0] : null;
      if (process.env.TRACE && a && out.frames % +process.env.TRACE === 0) console.log('  guide', a.act, a.target, a.why, a.actWhy);
      if (a && a.act) {
        gas = ['gas', 'boost', 'ready'].includes(a.act); brake = a.act === 'brake'; boost = a.act === 'boost';
        dive = a.act === 'dive'; noseUp = a.act === 'level';
        if (typeof a.target === 'number') target = a.target;
      }
    } else if (kind === 'lifter') {
      // Off the gas for a sharp corner that is close (as seen a moment ago), on it again once in
      // the corner; the inside of the corner; what it saw in the road, dodged.
      const lc = late ? ((late.pos + PLAYER_Z) >> 8) : chunk;
      // (off the gas from a little before the corner to its end: lc is where it was REACT ago)
      const near = [0, 1].map(k => bendAt(lc + k)).find(b => Math.abs(b) >= 16);
      if ((near !== undefined || Math.abs(bendAt(lc)) >= 16) && speed > 4) gas = false;   // (lifting, not stopping)
      if (Math.abs(bend) > 2) target = bend > 0 ? 36 : -36;
      dodge(480, lateObjs);
    } else if (kind === 'expert' || kind === 'human') {
      // Take each corner ahead no faster than the car can turn to follow it (F-Zero's turning at
      // full lock against the road's turn under it), and start braking for it in time.
      const car = pos + PLAYER_Z;
      let want = 12;
      // (human: plans from where it was REACT frames ago, and leaves itself a margin)
      const plan = kind === 'human' && late ? late.pos + PLAYER_Z : car, margin = kind === 'human' ? 0.35 : 0;
      for (let c = plan >> 8; c < (plan >> 8) + 4; c++) {
        const b = bendAt(c); if (Math.abs(b) < 2) continue;
        let end = c + 1; while (end < c + 4 && bendAt(end) === b) end++;
        const from = Math.max(plan, c * 256), v = limit(b) - margin;
        want = Math.min(want, Math.sqrt(Math.max(0, v * v + 2 * BRAKING * (from - plan))));
        c = end - 1;
      }
      const ahead = bendAt(car >> 8) || bendAt((car + 128) >> 8);
      if (Math.abs(ahead) > 2) target = ahead > 0 ? 36 : -36;        // the inside: the short way round
      if (kind === 'human') dodge(480, lateObjs); else dodge(480);
      if (healing && rd(sym.hHealth) < 30) want = Math.min(want, 4);      // badly hurt: cross it slowly for more
      if (speed > want + 0.15) { gas = false; brake = true; }       // (off the gas alone F-Zero's car barely slows)
      if (process.env.TRACE && out.frames % +process.env.TRACE === 0) console.log('  want', want.toFixed(2), 'limits 8/16', limit(8).toFixed(2), limit(16).toFixed(2), 'tab', [0, 16, 32, 48].map(q => rd(sym.wTurnTab + q)), 'sym', sym.wTurnTab && sym.wTurnTab.toString(16), 'bends', [0, 1, 2, 3].map(k => bendAt((plan >> 8) + k)));
      const straight = [0, 1, 2].every(k => Math.abs(bendAt(chunk + k)) < 3) && Math.abs(bend) < 3;
      if (boosts && straight && speed > 7.6) boost = true;
    }
    // Steering, as F-Zero's car turns: point it at the target (a step of facing for each 6 pixels
    // to go, up to 6), allowing for how fast the facing is already swinging (the turn carries on
    // a moment after the d-pad is let go).  (guided: as the guide said.)
    // (and for where it is going across the road, as a person sees it drift: a wind's push too)
    const vx = Math.abs(x - lastX) < 8 ? x - lastX : 0;
    if (steer === null) { const want = Math.max(-6, Math.min(6, (target - x - vx * 12) / 6)), err = want - face - (face - lastFace) * 8; steer = Math.abs(err) > 1 ? Math.sign(err) : 0; }
    lastFace = face; lastX = x;
    set('left', !air && steer < 0); set('right', !air && steer > 0);
    if (process.env.TRACE && out.frames % +process.env.TRACE === 0) console.log('t', out.frames, 'chunk', ((pos + PLAYER_Z) >> 8) & 63, 'x', x.toFixed(1), 'face', face.toFixed(2), 'speed', speed.toFixed(2), 'target', target, 'steer', steer, 'gas', gas, 'brake', brake, 'hp', rd(sym.hHealth));
    set('B', gas); set('A', brake); set('up', dive || (boost && !keys.up)); set('down', noseUp);
  }
  if (process.env.RECORD_INPUTS) fs.writeFileSync(process.env.RECORD_INPUTS, JSON.stringify(inputLog));
  if (process.env.RESULT_JSON) fs.writeFileSync(process.env.RESULT_JSON, JSON.stringify(out, null, 2) + '\n');
  if (record && frames.length) fs.writeFileSync(record[2] + '.rgba', Buffer.concat(frames));
  return out;
}

(async () => {
  ({ advise } = await import(require('url').pathToFileURL(path.join(ROOT, 'web/guide.js')).href));
  for (const kind of bots.length ? bots : KINDS) {
    const r = await race(kind, gifAt >= 0 ? [+args[gifAt + 2], +args[gifAt + 3], args[gifAt + 1]] : null);
    const laps = r.lapFrames.map((f, i) => ((f - (r.lapFrames[i - 1] || 0)) / 60).toFixed(1) + 's').join(' ');
    console.log(`track ${track} level ${r.level}  ${kind.padEnd(7)} ${r.wrecked ? 'WRECKED' : r.rankedOut ? `RANKED OUT in place ${r.place} after lap ${r.lapFrames.length}` : 'place ' + r.place}  time ${(r.frames / 60).toFixed(1)}s  laps ${laps}  health ${r.health} (low ${r.minHealth}, ${r.hits} hits)  place during race ${r.best}-${r.worst}  load ${Math.round(r.peak / 1.54)}% drops ${r.dropped}`);
    if (process.env.LOADAVG) console.log(`        mean load ${(r.sum / r.n / 1.54).toFixed(1)}%`);
    if (r.where) console.log('        health lost at chunk:amount  ' + r.where.join(' '));
    if (r.gaps) console.log('        rivals at the flag (units ahead of the player): ' + r.gaps.map(g => g > 20000 || g < -20000 ? '-' : g).join(' '));
  }
})();

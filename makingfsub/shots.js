// Capture rig for the blog figures: run the ROM headless in the web build's emulator, drive it
// (the bots are the ones in tools/playtest.js), and dump (picture, memory $8000-$FFFF) pairs.
//   node shots.js OUTDIR [--track N] [--mode race|practice] [--bot expert|casual|masher|none]
//                 [--frames N] [--every N] [--dense FROM,TO] [--script practice] [--wreck]
// --dense dumps every frame of a range; --script practice holds a list of bends and steering
// positions in practice mode and dumps each; --wreck dumps only while the car is exploding.
const fs = require('fs'), vm = require('vm'), path = require('path');
const ROOT = path.join(__dirname, '..');
vm.runInThisContext(fs.readFileSync(ROOT + '/web/binjgb.js', 'utf8') + '\nglobalThis.Binjgb = Binjgb;');
const sym = {};
for (const l of fs.readFileSync(ROOT + '/fzero.sym', 'utf8').split('\n')) { const m = l.match(/^[0-9a-f]{2}:([0-9a-f]{4}) (\w+)$/i); if (m) sym[m[2]] = parseInt(m[1], 16); }
const args = process.argv.slice(2);
const out = args[0];
const opt = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const track = +opt('track', 0), mode = opt('mode', 'race'), kind = opt('bot', 'expert');
const maxFrames = +opt('frames', 3000), every = +opt('every', 20), script = opt('script', ''), level = +opt('level', 0);
const dense = opt('dense', '0,0').split(',').map(Number), wreck = args.includes('--wreck');
fs.mkdirSync(out, { recursive: true });

(async () => {
  const m = await Binjgb({ wasmBinary: fs.readFileSync(ROOT + '/web/binjgb.wasm') });
  const rom = fs.readFileSync(ROOT + '/fzero.gb'); const size = (rom.length + 0x7fff) & ~0x7fff;
  const ptr = m._malloc(size); new Uint8Array(m.HEAP8.buffer, ptr, size).fill(0).set(rom);
  const e = m._emulator_new_simple(ptr, size, 44100, 4096, 2); m._emulator_set_default_joypad_callback(e, m._joypad_new());
  const rd = a => m._emulator_read_mem(e, a), s8 = v => (v << 24) >> 24;
  const keys = {}; const set = (k, v) => { if (!!keys[k] !== !!v) { keys[k] = !!v; m['_set_joyp_' + k](e, v ? 1 : 0); } };
  const ALL = ['up', 'down', 'left', 'right', 'A', 'B', 'select', 'start'];
  // run to the next completed frame (the moment the PPU enters VBlank), or a frame's worth of ticks
  const step = () => { const lim = m._emulator_get_ticks_f64(e) + 70224 * 1.5; for (;;) { const ev = m._emulator_run_until_f64(e, lim); if (ev & 1) return true; if (ev & 4) return false; } };
  const index = [];
  const dump = (name, extra) => {
    const fb = Buffer.from(new Uint8Array(m.HEAP8.buffer, m._get_frame_buffer_ptr(e), 160 * 144 * 4));
    const mem = Buffer.alloc(0x8000); for (let a = 0; a < 0x8000; a++) mem[a] = rd(0x8000 + a);
    fs.writeFileSync(path.join(out, name + '.rgba'), fb); fs.writeFileSync(path.join(out, name + '.mem'), mem);
    index.push(Object.assign({ name }, extra || {}));
  };
  const felt = v => ((v & 127) - 32) * (v & 128 ? 1.5 : 1);
  const bendAt = chunk => felt(rd(sym.wTrackBend + (chunk & 63)));
  const wantMode = { race: 0, practice: 1, link: 2 }[mode];
  let started = false, race = 0, menuShot = false;
  for (let i = 0; i < 60000 && race < maxFrames; i++) {
    step();
    if (i > 20 && rd(sym.hMenu)) {
      if (i > 60 && !menuShot && rd(sym.hTrackNo) === track && rd(sym.hMode) === wantMode) { dump('menu', { i }); menuShot = true; }
      const row = rd(sym.wMenuRow), trk = rd(sym.hTrackNo), lv = rd(sym.hLevel), md = rd(sym.hMode), tap = i % 6 < 3;
      let key = 'start';
      const goRow = r => row < r ? 'down' : 'up';
      if (trk !== track) key = row !== 0 ? goRow(0) : (trk < track ? 'right' : 'left');
      else if (level && lv !== level) key = row !== 1 ? goRow(1) : (lv < level ? 'right' : 'left');
      else if (md !== wantMode) key = row !== 2 ? goRow(2) : (md < wantMode ? 'right' : 'left');
      else if (!menuShot) key = 'none';
      for (const k of ALL) set(k, tap && k === key);
      continue;
    }
    if (!started) { for (const k of ALL) set(k, 0); if (i > 40 && (rd(0xFF40) & 0x80) && rd(sym.hFrame) > 2 && rd(sym.hFrame) < 40) started = true; else continue; }
    race++;
    const st = rd(sym.hState), x = s8(rd(sym.hX + 1)), speed = (rd(sym.hSpeed) | rd(sym.hSpeed + 1) << 8) / 256;
    const bend = (rd(sym.hBend) - 32) * (rd(sym.wTight) ? 1.5 : 1);
    const pos = rd(sym.hPos + 1) | rd(sym.hPos + 2) << 8, chunk = (pos >> 8) & 63, boosts = rd(sym.hBoosts), air = rd(sym.hAir);
    const meta = { race, chunk, x, speed: +speed.toFixed(2), bend: rd(sym.hBend), seen: rd(sym.hSeen + 1), shear: rd(sym.hShear), st, lap: rd(sym.hLap), hp: rd(sym.hHealth), rank: rd(sym.hRank),
      tunnel: rd(sym.hTunnel), fade: rd(sym.hFadeLevel), flash: rd(sym.hFlash), boom: rd(sym.hBoom), boost: rd(sym.hBoost), load: rd(sym.hLoad), front: rd(sym.hFront), count: rd(sym.hCount), air,
      obj: [rd(sym.wObjSlots), rd(sym.wObjSlots + 1), rd(sym.wObjSlots + 4), rd(sym.wObjSlots + 5)], lcdc: rd(0xFF40), stat: rd(0xFF41), ly: rd(0xFF44), obp0: rd(0xFF48), wy: rd(0xFF4A), wx: rd(0xFF4B), lapflash: rd(sym.hLapFlash) };
    if ((race % every === 0 && (!wreck || st === 2)) || (race >= dense[0] && race < dense[1])) dump('f' + String(race).padStart(5, '0'), meta);
    if (script === 'practice') {
      // practice mode lets Select/Start bend the road by hand: hold each (bend, x, speed) and dump it
      const P = [['straight', 32, 0, 7], ['bend-right-16', 48, 0, 5], ['bend-right-32', 64, 0, 3.6], ['bend-left-32', 0, 0, 3.6], ['bend-left-20', 12, 0, 4.6],
                 ['steer-left', 32, -40, 6], ['steer-right', 32, 40, 6], ['bend-right-steer-right', 52, 34, 4.2], ['bend-left-steer-right', 14, 30, 4.4], ['bend-right-steer-left', 50, -34, 4.2]];
      globalThis.ph = globalThis.ph || { k: 0, ok: 0 };
      const ph = globalThis.ph; if (ph.k >= P.length) break;
      const [name, wantBend, wantX, wantSpeed] = P[ph.k], tgt = rd(sym.hTarget);
      set('select', tgt > wantBend && race % 2 === 0); set('start', tgt < wantBend && race % 2 === 0);
      set('B', speed < wantSpeed); set('A', speed > wantSpeed + 0.4);
      set('left', x > wantX + 1); set('right', x < wantX - 1);
      const good = rd(sym.hBend) === wantBend && rd(sym.hSeen + 1) === wantBend && Math.abs(x - wantX) <= 3 && Math.abs(speed - wantSpeed) < 0.7;
      ph.ok = good ? ph.ok + 1 : 0;
      if (ph.ok > 24 && (rd(sym.hFrame) & 15) === 3) { dump('p-' + name, meta); ph.k++; ph.ok = 0; }
      continue;
    }
    if (st !== 0 && rd(sym.hBoom) > 76 || (st === 1 && speed < 0.2)) { dump('end', meta); break; }
    let target = 0, gas = true, brake = false, boost = false, healing = false;
    const objs = [];
    for (let k = 0; k < 2; k++) { const a = sym.wObjSlots + k * 4; if (rd(a)) objs.push({ kind: rd(a + 1), dist: ((rd(a + 2) | rd(a + 3) << 8) - pos) & 0xffff }); }
    const dodge = reach => { for (const o of objs) { if (o.dist > reach) continue;
      if (o.kind === 0) { if (kind === 'expert') target = -24; else if (x < 0) target = 14; }
      else if (o.kind <= 4) { const lane = [-36, -12, 12, 36][o.kind - 1]; const at = target || x;
        if (Math.abs(at - lane) < 22) target = (o.kind === 2 || o.kind === 3) ? (at < 0 ? -38 : 38) : (lane > 0 ? lane - 30 : lane + 30); }
      else if (o.kind <= 6) target = o.kind === 5 ? 22 : -22;
      else if (o.kind <= 8) { if (kind !== 'masher') target = o.kind === 7 ? -24 : 24; }
      else if (kind !== 'masher' && rd(sym.hHealth) < 52) { target = o.kind === 9 ? -24 : 24; healing = true; } } };
    if (kind === 'casual') {
      dodge(330);
      if (Math.abs(bend) > 16 && speed > 6.2 && Math.abs(x) > 20) brake = true;
      if (boosts && bend === 0 && bendAt(chunk + 1) === 0 && speed > 7.5) boost = true;
    } else if (kind === 'expert') {
      const limit = b => Math.abs(b) < 2 ? 12 : 8 * Math.sqrt(12.3 / Math.abs(b));
      let want = Math.min(limit(bend), limit(bendAt(chunk)), limit(bendAt((pos + 230) >> 8)));
      const ahead = bendAt(chunk) || bend;
      if (Math.abs(ahead) > 8) target = ahead > 0 ? 18 : -18;
      dodge(480);
      if (healing && rd(sym.hHealth) < 30) want = Math.min(want, 4);
      if (speed > want + 0.15) { gas = false; brake = speed > want + 0.5; }
      const straight = [0, 1, 2].every(k => Math.abs(bendAt(chunk + k)) < 3) && Math.abs(bend) < 3;
      if (boosts && straight && speed > 7.6) boost = true;
    }
    set('left', !air && x > target + 2); set('right', !air && x < target - 2);
    set('B', gas); set('A', brake); set('up', boost && !keys.up);
  }
  fs.writeFileSync(path.join(out, 'index.json'), JSON.stringify(index));
  console.log(out, 'dumps', index.length, 'race frames', race);
})();

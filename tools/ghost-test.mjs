// Records and the ghost (web/ghost.js) in Node: a race on Gold Wind with no rivals makes a
// record and a ghost; then the ghost is plugged into the link cable (web/link.js) and a
// slower second race is run against it.  Checks that the record is kept, that the ghost
// links, never restarts the race, runs ahead of the slower car, and finishes first.
//
//   node tools/ghost-test.mjs [rom] [web-dir]
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROM = process.argv[2] || path.join(here, "..", "fzero.gb");
const WEB = process.argv[3] || path.join(here, "..", "web");
const { Cable, EV_SERIAL } = await import(path.join(WEB, "link.js"));
const { RaceLog, GhostPartner, clock } = await import(path.join(WEB, "ghost.js"));
vm.runInThisContext(fs.readFileSync(path.join(WEB, "binjgb.js"), "utf8"));
const sym = Object.fromEntries(fs.readFileSync(ROM.replace(/\.gb$/, ".sym"), "utf8").split("\n")
  .map((l) => /^[0-9a-f]+:([0-9a-f]{4}) (\S+)$/i.exec(l)).filter(Boolean).map((m) => [m[2], parseInt(m[1], 16)]));
let failures = 0;
const check = (what, ok, detail) => { if (!ok) failures++; console.log(`${ok ? "ok  " : "FAIL"} ${what}${detail === undefined ? "" : ": " + JSON.stringify(detail)}`); };

const wasm = fs.readFileSync(path.join(WEB, "binjgb.wasm"));
const m = await globalThis.Binjgb({ instantiateWasm: (info, cb) => { WebAssembly.instantiate(wasm, info).then((r) => cb(r.instance)); return {}; }, print() {}, printErr() {} });
const rom = fs.readFileSync(ROM), size = (rom.length + 0x7fff) & ~0x7fff, p = m._malloc(size);
new Uint8Array(m.HEAP8.buffer, p, size).fill(0).set(rom);
const e = m._emulator_new_simple(p, size, 44100, 4096, 2);
m._emulator_set_default_joypad_callback(e, m._joypad_new());
const rd = (a) => m._emulator_read_mem(e, a), s8 = (v) => (v << 24) >> 24, s16 = (v) => (v << 16) >> 16;
const key = (k, v) => m["_set_joyp_" + k](e, v ? 1 : 0);

const store = new Map(), local = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)) };
let ghost = null, finishes = [];
const cable = new Cable({ m, e, now: () => frame * 1000 / 59.73, send: (b) => ghost && ghost.receive(b) });
const log = new RaceLog({ rd, sym, store: local, kind: () => (ghost ? "ghost" : rd(sym.hMode) === 0 ? "solo" : "other"), on: (ev, d) => { if (d.state === 1) finishes.push(d); } });

const FRAME = 70224, SLICE = 12288;
let frame = 0, ticks = 0;
function run(n, each) {
  for (let i = 0; i < n; i++, frame++) {
    const end = (frame + 1) * FRAME;
    for (;;) {
      const t = m._emulator_get_ticks_f64(e);
      if (t >= end) break;
      const ev = m._emulator_run_until_f64(e, cable.plugged ? Math.min(end, t + SLICE) : end);
      if (ev & EV_SERIAL) cable.serial();
      if (ev & 1) { log.frame(); if (ghost) ghost.frame(); }
      if (ev & 4) cable.tick();
    }
    if (each) each();
  }
}
const tap = (k, n = 3) => { key(k, 1); run(n); key(k, 0); run(n); };
// A plain driver: the gas, the middle of the road, the inside of a bend; lift: let go of the
// gas for that share of the frames (a slower run).
const drive = (lift) => () => {
  const x = s8(rd(sym.hX + 1)), bend = rd(sym.hBend) - 32, target = Math.abs(bend) > 2 ? Math.sign(bend) * 20 : 0;
  key("left", x > target + 3); key("right", x < target - 3);
  key("B", !(lift && frame % 10 < lift * 10));
};

run(120);
tap("right"); tap("right"); tap("down"); tap("down"); for (let k = 0; k < 4; k++) tap("left");   // Gold Wind, RIVALS NONE (past CAR)
check("menu: Gold Wind, no rivals", rd(sym.hTrackNo) === 2 && rd(sym.hLevel) === 0, [rd(sym.hTrackNo), rd(sym.hLevel)]);
tap("start");
for (let k = 0; k < 9000 && rd(sym.hState) === 0; k++) run(1, drive(0));
for (const k of ["B", "left", "right"]) key(k, 0);
run(30);
const first = finishes[0];
check("the race is finished and timed", !!first && first.laps === 3 && first.lapTimes.length === 3, first && { total: clock(first.total), laps: first.lapTimes.map(clock) });
check("a record and a ghost are kept", first && first.record.race && !!log.ghost(2, 3) && log.records(2).race3 === first.total, Object.keys(Object.fromEntries(store)));

// Back to the menu (Select once the race is over), MODE to LINK, the ghost plugged in.
tap("select"); run(60);
check("back in the menu", rd(sym.hMenu) === 1);
m._emulator_write_mem(e, sym.hMode, 2); m._emulator_write_mem(e, sym.wMenuDirty, 1); run(10);   // (as the page does)
check("MODE is LINK", rd(sym.hMode) === 2, rd(sym.hMode));
ghost = new GhostPartner({ rd, sym, cable, data: log.ghost(2, 3) });
cable.plug(true, true);
tap("B"); run(30);
// The page presses Start for its player when both wait (cable.autoCall): so here.
let pressed = 0;
for (let k = 0; k < 120 && cable.state !== "master"; k++) run(1, () => { if (cable.autoCall()) { key("start", 1); pressed++; } else key("start", 0); });
key("start", 0);
run(10);   // (the Game Boy takes the answer on its next frame, and starts the race afresh: the countdown)
check("linked with the ghost: our Game Boy calls, the ghost answers", cable.state === "master" && rd(sym.hLinked) === 1, [cable.state, rd(sym.hLinked), pressed]);

// The second race, slower (off the gas a fifth of the time): the ghost should pull ahead.
let restarts = 0, lastCount = rd(sym.hCount), ahead = 0, samples = 0;
const ghostGap = () => s16(rd(sym.wRivals + 4 * 8 + 1) | rd(sym.wRivals + 4 * 8 + 2) << 8) - 175;
for (let k = 0; k < 12000 && rd(sym.hState) === 0; k++) run(1, () => {
  drive(0.2)();
  const c = rd(sym.hCount); if (c > lastCount) restarts++; lastCount = c;
  if (!c && frame % 30 === 0) { samples++; if (ghostGap() > 0) ahead++; }
});
run(30);
const second = finishes[1];
check("the race against the ghost was never restarted", restarts === 0, restarts);
check("the ghost is ahead of the slower car most of the race", ahead > samples * 0.8, { ahead, samples });
check("the ghost wins: the slower car is second", rd(sym.hRank) === 2, rd(sym.hRank));
check("the slower race is no record", second && !second.record.race && log.records(2).race3 === first.total, second && { total: clock(second.total), best: clock(log.records(2).race3) });

if (process.env.GHOST_OUT) fs.writeFileSync(process.env.GHOST_OUT, JSON.stringify(Object.fromEntries(store)));   // (for a page test)
console.log(failures ? `${failures} FAILED` : "all ok");
process.exit(failures ? 1 : 0);

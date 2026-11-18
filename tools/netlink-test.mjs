// Two fsub Game Boys linked through web/link.js over a simulated network
// (delay, jitter, lost and reordered best-effort messages), in Node.
//
//   node tools/netlink-test.mjs [rom] [web-dir]     (defaults: fzero.gb, web/)
//
// Checks: a call is taken and the Game Boys stay linked through a race; the
// one that called picks the track; one player leaving drops the link on both
// sides; both calling at once still links them, one clocking and one
// answering; and the remote cars move on each screen.
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROM = process.argv[2] || path.join(here, "..", "fzero.gb");
const WEB = process.argv[3] || path.join(here, "..", "web");
const { Cable, EV_SERIAL } = await import(path.join(WEB, "link.js"));
vm.runInThisContext(fs.readFileSync(path.join(WEB, "binjgb.js"), "utf8"));
const wasm = fs.readFileSync(path.join(WEB, "binjgb.wasm"));

const sym = Object.fromEntries(fs.readFileSync(ROM.replace(/\.gb$/, ".sym"), "utf8").split("\n")
  .map((l) => /^[0-9a-f]+:([0-9a-f]{4}) (\S+)$/i.exec(l)).filter(Boolean).map((m) => [m[2], parseInt(m[1], 16)]));
const FRAME = 70224, MS = 4194304 / 1000, EV_TICKS = 4, SLICE = 12288;
const LATENCY = Number(process.env.LATENCY || 60), JITTER = Number(process.env.JITTER || 25), LOSS = Number(process.env.LOSS || 0.03);

let failures = 0;
const check = (what, ok, detail) => { if (!ok) failures++; console.log(`${ok ? "ok  " : "FAIL"} ${what}${detail === undefined ? "" : ": " + JSON.stringify(detail)}`); };

// A deterministic random for the network.
let seed = 12345;
const rand = () => ((seed = (seed * 1103515245 + 12345) >>> 0) / 4294967296);

let clockMs = 0;   // shared wall clock: both Game Boys run in step with it
const wire = [];   // { at, to, data }
async function gameBoy(name) {
  const m = await globalThis.Binjgb({ instantiateWasm: (info, cb) => { WebAssembly.instantiate(wasm, info).then((r) => cb(r.instance)); return {}; }, print: () => {}, printErr: () => {} });
  const rom = fs.readFileSync(ROM);
  const size = (rom.length + 0x7fff) & ~0x7fff, p = m._malloc(size);
  new Uint8Array(m.HEAP8.buffer, p, size).fill(0).set(rom);
  const e = m._emulator_new_simple(p, size, 44100, 4096, 2);
  m._emulator_set_default_joypad_callback(e, m._joypad_new());
  const gb = { name, m, e, log: [], rd: (a) => m._emulator_read_mem(e, a), key: (k, v) => m["_set_joyp_" + k](e, v ? 1 : 0) };
  let lastSeq = 0;
  gb.cable = new Cable({
    m, e, now: () => clockMs, log: (l) => gb.log.push(`${clockMs.toFixed(0)} ${l}`),
    send: (data, reliable) => {
      if (!reliable && rand() < LOSS) return;
      // Reliable messages keep their order; best-effort ones may overtake each other.
      let at = clockMs + LATENCY + rand() * JITTER;
      if (reliable) { at = Math.max(at, lastSeq); lastSeq = at; }
      wire.push({ at, to: name === "A" ? "B" : "A", data: data.slice() });
    },
  });
  return gb;
}
const A = await gameBoy("A"), B = await gameBoy("B");
const gbs = { A, B };

let frame = 0;
function run(frames, each) {
  for (let i = 0; i < frames; i++, frame++) {
    for (const gb of [A, B]) {
      const end = (frame + 1) * FRAME;
      for (;;) {
        const t = gb.m._emulator_get_ticks_f64(gb.e);
        if (t >= end) break;
        const ev = gb.m._emulator_run_until_f64(gb.e, gb.cable.plugged ? Math.min(end, t + SLICE) : end);
        if (ev & EV_SERIAL) gb.cable.serial();
        if (ev & EV_TICKS) gb.cable.tick();
      }
    }
    clockMs = (frame + 1) * FRAME / MS;
    const due = wire.filter((w) => w.at <= clockMs).sort((a, b) => a.at - b.at);
    for (const w of due) { wire.splice(wire.indexOf(w), 1); gbs[w.to].cable.receive(w.data); }
    if (each) each();
  }
}
const tap = (gb, k, n = 3) => { gb.key(k, 1); run(n); gb.key(k, 0); run(n); };
const H = (gb, s) => gb.rd(sym[s]);
const linked = () => [H(A, "hLinked"), H(B, "hLinked")];
const pos = (gb) => gb.rd(sym.hPos + 1) | gb.rd(sym.hPos + 2) << 8;
const remotePos = (gb) => { const r = sym.wRemote; return gb.rd(r + 1) | gb.rd(r + 2) << 7 | (gb.rd(r + 3) & 3) << 14; };
// The other cars this Game Boy places on the road (a record at HIDDEN is nobody).
const HIDDEN = -30000 & 0xffff;
const carsShown = (gb) => { let n = 0; for (let i = 0; i < 7; i++) { const d = gb.rd(sym.wRivals + i * 8 + 1) | gb.rd(sym.wRivals + i * 8 + 2) << 8; if (d !== HIDDEN) n++; } return n; };

run(240);
// Both pick LINK (and A the third track); then GAS brings up the race screen ("2P").
for (const gb of [A, B]) { tap(gb, "down"); tap(gb, "down"); tap(gb, "right"); tap(gb, "right"); }
tap(A, "up"); tap(A, "up"); tap(A, "right"); tap(A, "right");
check("menu: both in link mode, A on track 2", H(A, "hMode") === 2 && H(B, "hMode") === 2 && H(A, "hTrackNo") === 2 && H(B, "hTrackNo") === 0, [H(A, "hMode"), H(B, "hMode"), H(A, "hTrackNo"), H(B, "hTrackNo")]);
A.cable.plug(true); B.cable.plug(false);
tap(A, "B"); tap(B, "B"); run(90);
check("race screens up, waiting (2P), nobody linked", H(A, "hMenu") === 0 && H(B, "hMenu") === 0 && linked().join() === "0,0", linked());
check("each page sees the other listening", A.cable.peer.listening && B.cable.peer.listening, [A.cable.peer, B.cable.peer]);

// A calls.
tap(A, "start", 2); run(30);
check("A's call taken: A clocks, B answers", linked().join() === "1,2" && A.cable.state === "master" && B.cable.state === "slave", [linked(), A.cable.state, B.cable.state]);
run(30);
check("B follows the caller's track", H(B, "hTrackNo") === 2, H(B, "hTrackNo"));

// Race 20 s, both on the gas; watch the link and the other car.
let worstStale = 0, drops = 0, prev = linked().join();
const seenA = new Set(), seenB = new Set();
A.key("B", 1); B.key("B", 1);
run(1200, () => {
  worstStale = Math.max(worstStale, H(A, "hLinkStale"), H(B, "hLinkStale"));
  const l = linked().join(); if (l !== prev) { drops++; prev = l; }
  if (frame % 30 === 0) { seenA.add(remotePos(A)); seenB.add(remotePos(B)); }
});
check("linked through 20 s of racing", linked().join() === "1,2" && drops === 0, { linked: linked(), drops });
check("no long gap in good packets (frames)", worstStale < 30, worstStale);
check("each screen's other car moves", seenA.size > 20 && seenB.size > 20, [seenA.size, seenB.size]);
check("each screen races five others (the other player, two rivals each)", carsShown(A) === 5 && carsShown(B) === 5, [carsShown(A), carsShown(B)]);
check("the other car is where the other Game Boy is (within 2 s of driving)", Math.abs(remotePos(A) - (pos(B) & 0xffff)) < 3000 && Math.abs(remotePos(B) - (pos(A) & 0xffff)) < 3000, [remotePos(A), pos(B), remotePos(B), pos(A)]);
console.log("     packets A->B", A.cable.stats, "B->A", B.cable.stats);

// B goes back to the menu (Select+Start): the link drops on both.
A.key("B", 0); B.key("B", 0);
B.key("select", 1); B.key("start", 1); run(4); B.key("select", 0); B.key("start", 0);
run(300);
check("B in the menu; both pages dropped the link; A's Game Boy gave up", H(B, "hMenu") === 1 && A.cable.state === "waiting" && B.cable.state === "waiting" && H(A, "hLinked") === 0, [H(B, "hMenu"), A.cable.state, B.cable.state, linked()]);
console.log("     " + A.log.slice(-2).join(" | ") + " || " + B.log.slice(-2).join(" | "));

// B comes back; both press Start in the same frame.
tap(B, "B"); run(60);
A.key("start", 1); B.key("start", 1); run(2); A.key("start", 0); B.key("start", 0); run(60);
check("both called at once: one clocks, one answers", ["1,2", "2,1"].includes(linked().join()) && [A.cable.state, B.cable.state].sort().join() === "master,slave", [linked(), A.cable.state, B.cable.state]);
run(300);
check("still linked 5 s later", ["1,2", "2,1"].includes(linked().join()), linked());

// The other page goes away (closed tab): A's side unplugs B... and B's Game Boy is alone.
B.cable.unplug();
run(360);
check("B unplugged: both Game Boys give up the link", linked().join() === "0,0" && A.cable.state === "waiting", [linked(), A.cable.state]);

// Paired again while both Game Boys wait (2P): the lower seat's page presses Start for
// its player (as web/index.html does when cable.autoCall() says so); nobody else does.
A.cable.unplug(); A.cable.plug(true); B.cable.plug(false);
check("both waiting again (2P), nobody linked", linked().join() === "0,0" && A.cable.listening() && B.cable.listening(), [linked()]);
let autoPresses = { A: 0, B: 0 };
run(180, () => { for (const gb of [A, B]) {
  if (gb.autoLeft) { if (--gb.autoLeft === 0) gb.key("start", 0); }
  else if (gb.cable.autoCall()) { gb.key("start", 1); gb.autoLeft = 6; autoPresses[gb.name]++; }
} });
check("linked with no player pressing Start: the lower seat's page called", linked().join() === "1,2" && autoPresses.A >= 1 && autoPresses.B === 0, [linked(), autoPresses]);

// Heads-up: back to the menu, A sets RIVALS to NONE; B keeps NORMAL and follows A's.
A.key("select", 1); A.key("start", 1); run(4); A.key("select", 0); A.key("start", 0);
B.key("select", 1); B.key("start", 1); run(4); B.key("select", 0); B.key("start", 0);
run(60);
tap(A, "down"); for (let i = 0; i < 4; i++) tap(A, "left");   // (from the TRACK line: RIVALS, then down to NONE)
check("A's menu: RIVALS NONE, B's NORMAL", H(A, "hLevel") === 0 && H(B, "hLevel") === 3, [H(A, "hLevel"), H(B, "hLevel")]);
tap(A, "B"); tap(B, "B");
autoPresses = { A: 0, B: 0 };
run(240, () => { for (const gb of [A, B]) {
  if (gb.autoLeft) { if (--gb.autoLeft === 0) gb.key("start", 0); }
  else if (gb.cable.autoCall()) { gb.key("start", 1); gb.autoLeft = 6; autoPresses[gb.name]++; }
} });
check("heads-up: linked, and B took A's RIVALS NONE", linked().join() === "1,2" && H(B, "hLevel") === 0, [linked(), H(B, "hLevel"), autoPresses]);
// (A sets off 3 s before B, so that the order is plain: two cars side by side are each a
// few frames behind on the other's screen, and both may see themselves second.)
A.key("B", 1); run(180); B.key("B", 1); run(300);
let places = new Set();
run(600, () => { if (frame % 15 === 0) places.add(`${H(A, "hRank")}${H(B, "hRank")}`); });
A.key("B", 0); B.key("B", 0);
check("heads-up: each screen shows just the other player", carsShown(A) === 1 && carsShown(B) === 1, [carsShown(A), carsShown(B)]);
check("heads-up: A 1st and B 2nd on both screens", [...places].every((p) => p === "12"), [...places]);
check("heads-up: still linked after 15 s", linked().join() === "1,2", linked());

console.log(failures ? `${failures} FAILED` : "all ok");
process.exit(failures ? 1 : 0);

// Records and ghosts: something to chase.
//
// RaceLog watches every frame the Game Boy runs (frame()): it times the race and each lap
// from the frame the countdown ends, and keeps where the car was each frame (its place
// along the course, two bytes, and its x, one).  When a race is finished it keeps, in this
// browser, the best lap and the best race on that track (for three laps and for five), and
// the best race itself, frame by frame: the ghost.
//
// GhostPartner races that ghost against you.  It is the far end of the link cable
// (web/link.js) in place of another browser: the page sets MODE to LINK and plugs it in,
// it says it is waiting, takes your Game Boy's call, and then sends what the ghost's
// Game Boy would have sent, frame for frame of your race: the ghost's place and x in the
// ROM's own packet (fzero.asm, "Link cable"), with no rivals of its own (level 0 in the last
// byte) and your Game Boy's own restart bit, so that it never restarts your race.  Your
// Game Boy shows it as the other player's car.
//
// Only races against the rivals or against a ghost count (not practice, not a race with
// somebody in another browser).

import { WIRE } from "./link.js";

const FPS = 4194304 / 70224;                       // the Game Boy's frame rate, 59.73
export const TRACKS = ["NEO CITY", "BLUE DEEP", "GOLD WIND", "OLD PORT"];
const MODE_RACE = 0, MODE_LINK = 2, FINISHED = 1;

export const clock = (frames) => {                 // 1:32.4
  const s = frames / FPS, m = Math.floor(s / 60);
  return (m ? `${m}:${(s - m * 60).toFixed(1).padStart(4, "0")}` : s.toFixed(1)) + (m ? "" : " s");
};
const get = (store, key) => { try { return store.getItem(key); } catch (e) { return null; } };
const put = (store, key, v) => { try { store.setItem(key, v); return true; } catch (e) { return false; } };
const toB64 = (bytes) => { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); return btoa(s); };
const fromB64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

// rd, sym: the Game Boy's memory.  kind(): "solo" | "ghost" | other (not counted).
// on(event, detail): "finish" { track, laps, total, bestLap, lapTimes, record: {race, lap} }.
export class RaceLog {
  constructor({ rd, sym, kind, store = localStorage, on = () => {} }) {
    Object.assign(this, { rd, sym, kind, store, on });
    this.run = null;
  }
  records(track) {
    try { return JSON.parse(get(this.store, "fsub:records") || "{}")[track] || {}; } catch (e) { return {}; }
  }
  ghost(track, laps) {
    const s = get(this.store, `fsub:ghost:${track}:${laps}`);
    try { return s ? fromB64(s) : null; } catch (e) { return null; }
  }
  frame() {
    const { rd, sym } = this;
    if (rd(sym.hMenu)) { this.run = null; return; }
    const count = rd(sym.hCount), state = rd(sym.hState);
    if (count) {                                   // the countdown: a race is about to start
      if (!this.run || this.run.frames) this.run = { frames: 0, lap: rd(sym.hLap), lapStart: 0, lapTimes: [], track: rd(sym.hTrackNo), laps: rd(sym.hLaps), kind: this.kind(), samples: [] };
      return;
    }
    const r = this.run;
    if (!r || r.done) return;
    if (state === 0) {
      r.frames++;
      const pos = rd(sym.hPos + 1) | rd(sym.hPos + 2) << 8;
      r.samples.push(pos & 255, pos >> 8, rd(sym.hX + 1));
      const lap = rd(sym.hLap);
      if (lap !== r.lap) { r.lapTimes.push(r.frames - r.lapStart); r.lapStart = r.frames; r.lap = lap; }
      return;
    }
    r.done = true;
    if (state !== FINISHED || (r.kind !== "solo" && r.kind !== "ghost")) return;   // wrecked, ranked out, or not counted
    r.lapTimes.push(r.frames - r.lapStart);
    const all = (() => { try { return JSON.parse(get(this.store, "fsub:records") || "{}"); } catch (e) { return {}; } })();
    const rec = all[r.track] || {}, key = `race${r.laps}`, bestLap = Math.min(...r.lapTimes);
    const record = { race: !rec[key] || r.frames < rec[key], lap: !rec.lap || bestLap < rec.lap };
    if (record.race) {
      rec[key] = r.frames;
      put(this.store, `fsub:ghost:${r.track}:${r.laps}`, toB64(Uint8Array.from(r.samples)));
    }
    if (record.lap) rec.lap = bestLap;
    all[r.track] = rec;
    put(this.store, "fsub:records", JSON.stringify(all));
    this.on("finish", { track: r.track, laps: r.laps, total: r.frames, bestLap, lapTimes: r.lapTimes, record });
  }
}

// The ghost at the far end of the cable.  cable: link.js's Cable (its send must come here
// while the ghost is plugged in: receive()); data: RaceLog.ghost().
export class GhostPartner {
  constructor({ rd, sym, cable, data }) {
    Object.assign(this, { rd, sym, cable, data });
    this.frames = data ? data.length / 3 : 0;
    this.i = 0; this.seq = 0; this.tick = 0; this.which = 0;
  }
  // From our cable: take a call at once.
  receive(bytes) {
    const d = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    if (d[0] === WIRE.M_CALL) this.cable.receive(Uint8Array.of(WIRE.M_ACCEPT));
  }
  // Every frame the Game Boy runs.
  frame() {
    const { rd, sym, cable } = this;
    if (!cable.plugged) return;
    if (cable.role === null) {                     // waiting for the call: say so, twice a second
      if (this.tick++ % 30 === 0) cable.receive(Uint8Array.of(WIRE.M_STATUS, 1));
      this.i = 0;
      return;
    }
    if (rd(sym.hCount)) this.i = 0;                // the countdown: on the line
    else if (rd(sym.hState) === 0 && this.i < this.frames - 1) this.i++;
    if (this.tick++ % 2) return;
    const at = Math.min(this.i + 3, this.frames - 1);   // (a few frames on: the packet takes that long to arrive)
    const k = at * 3, pos = this.data[k] | this.data[k + 1] << 8, x = this.data[k + 2];
    const done = this.i >= this.frames - 1 ? FINISHED : 0;
    const p = new Uint8Array(9);
    p[0] = 0x80 | (rd(sym.hTrackNo) & 3) << 2 | (rd(sym.hGen) & 1) << 1 | (this.which ^= 1);
    p[1] = pos & 0x7f;
    p[2] = (pos >> 7) & 0x7f;
    p[3] = ((pos >> 14) & 3) | ((x >> 7) & 1) << 2 | done << 4;
    p[4] = x & 0x7f;
    let sum = 0;
    for (let j = 1; j <= 7; j++) sum += p[j];
    p[8] = sum & 0x7f;
    this.seq = (this.seq + 1) & 0xffff;
    cable.receive(Uint8Array.of(WIRE.M_PACKET, this.seq >> 8, this.seq & 255, ...p));
  }
}

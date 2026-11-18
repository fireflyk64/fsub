// The guide: reads the race out of the Game Boy's memory and says what to press, a moment
// before it is needed, so that somebody new to the game learns where to brake.
//
// advise(rd, sym) looks at the car (speed, place on the road, which lane), the course ahead
// (the bend of each chunk, as the game itself holds it) and what is on the road (the two
// object slots), and works out what a good driver does LEAD frames from now -- about the
// time a person takes to act on what they are told:
//   * speed: BRAKE, LIFT (let go of the gas: coasting slows the car and it grips a corner
//     better), GAS, or BOOST on a clear straight.  A corner is taken no faster than lets
//     the bend throw the car 40 pixels out before it ends (the push goes with the square of
//     the speed, against 1.5 pixels a frame of steering; three quarters of it off the gas).
//     Lift when coasting from here just gets the car down to that speed by the corner;
//     brake when coasting alone would not.
//   * steering: out of a barrier's lane, off the dirt, onto the inside of a corner (the
//     short way round: fzero.asm's racing line), over a recharge patch when hurt, onto a
//     boost pad.
// The numbers are fzero.asm's (PLAYER_Z, PUSH_K, FRICTION, BRAKE, the lanes); the places in
// memory come from fsub.sym.  tools/playtest.js has a "guided" bot that does what the guide
// says, a person's reaction late, to check that following it gets round.
//
// createGuide(...) shows the advice over the top of the screen, and lights the touch
// buttons it is about.

const PLAYER_Z = 175;                            // the car is this far ahead of the camera
const PUSH = 72 * 16 / 1024 / 2 / 256;           // PUSH_K: a bend's push per speed^2 per bend level
const STEER = 1.5;                               // STEER_MAX / 16: pixels a frame of steering
const GRIP = 0.75;                               // off the gas the push is three quarters
const COAST = 10 / 256, BRAKING = 0x14 / 256;    // FRICTION, BRAKE: speed lost a frame
const LANES = [-36, -12, 12, 36];                // barrier lanes, kinds 1-4 (a hit within 13 pixels)
const SPOTS = [-40, -24, 0, 24, 40];             // where to be to miss them (18 or more pixels off)
let held = { key: "", target: null };            // the spot chosen for the barriers in view
let told = null;                                 // where the last advice sent the car
export const LEAD = 20;                          // frames: how far ahead of the car the advice looks

// The fastest a bend b can be taken over len units, letting it throw the car 40 pixels out.
function limit(b, len, grip) {
  let v = 12;
  while (v > 2 && (grip * PUSH * v * v * Math.abs(b) - STEER) * len / v > 40) v -= 0.05;
  return v;
}

export function advise(rd, sym, lead = LEAD) {
  if (rd(sym.hMenu)) { told = null; return null; }
  const state = rd(sym.hState);
  if (state) { told = null; return { act: "done" }; }
  if (rd(sym.hCount)) { told = null; return { act: "ready" }; }
  const s8 = (v) => (v << 24) >> 24;
  const speed = (rd(sym.hSpeed) | rd(sym.hSpeed + 1) << 8) / 256;
  const pos = rd(sym.hPos + 1) | rd(sym.hPos + 2) << 8;
  const x = s8(rd(sym.hX + 1)), health = rd(sym.hHealth);
  const bends = rd(sym.hTunnel) ? sym.wTunnelBend : sym.wTrackBend;
  const bendAt = (c) => { const v = rd(bends + (c & 63)); return ((v & 127) - 32) * (v & 128 ? 1.5 : 1); };
  const car = pos + PLAYER_Z, ahead = car + speed * lead;

  // --- speed: the most pressing of the corners in the next few chunks
  const rank = { gas: 0, lift: 1, brake: 2 };
  let act = "gas", corner = 0;
  for (let c = ahead >> 8; c < (ahead >> 8) + 4; c++) {
    const b = bendAt(c);
    if (Math.abs(b) < 3) continue;
    let end = c + 1;
    while (end < c + 5 && bendAt(end) === b) end++;
    const from = Math.max(ahead, c * 256), len = end * 256 - from, d = from - ahead;
    const full = limit(b, len, 1), grip = limit(b, len, GRIP);
    let a = "gas";
    if (speed > full + 0.1) {
      if (d <= 0) a = speed > grip + 0.25 ? "brake" : "lift";                     // in it: off the gas, brake if still too fast
      else {
        const need = speed * speed - grip * grip;                                // to shed before the corner
        if (need > 0 && d < need / (2 * COAST)) a = "brake";                       // coasting alone will not do it
        else if (need > 0 ? d < need / (2 * COAST) + speed * 8 : d < speed * 8) a = "lift";
      }
    }
    if (rank[a] > rank[act]) { act = a; corner = b; }
    c = end - 1;
  }

  // --- steering: where on the road to be, and why
  let target = 0, why = "", danger = false;
  const here = bendAt(car >> 8) || bendAt((car + 128) >> 8);
  // (the inside is the short way round: the car covers more of the course there)
  if (Math.abs(here) > 2) { target = here > 0 ? 30 : -30; why = "the inside: the short way round"; }
  const objs = [];
  for (let k = 0; k < 2; k++) {
    const a = sym.wObjSlots + k * 4;
    if (!rd(a)) continue;
    const dist = ((rd(a + 2) | rd(a + 3) << 8) - pos) & 0xffff;
    if (dist < 0x8000 && dist > PLAYER_Z - 10) objs.push({ kind: rd(a + 1), dist });
  }
  objs.sort((p, q) => p.dist - q.dist);
  // Barriers: a spot clear of every one in view, the nearest to the car, and the same one for
  // as long as the same barriers are in view (no dithering between two ways round).
  const barriers = objs.filter((o) => o.kind >= 1 && o.kind <= 4);
  if (barriers.length) {
    const lanes = barriers.map((o) => LANES[o.kind - 1]), key = barriers.map((o) => o.kind).join();
    const clear = (p) => lanes.every((l) => Math.abs(p - l) >= 18);
    // Where the car is going: where the advice so far has been sending it (the player is
    // still doing that while they take in the new), or else 0.2 s on at its sideways speed.
    // A spot is chosen when the car is in a barrier's way or heading into it: on that side
    // of the barriers if there is room there (never across a barrier's lane), the nearest;
    // and kept while it is clear.
    const vx = s8(rd(sym.hVX)) / 16, at = Math.max(-44, Math.min(44, told ?? x + vx * 12));
    if (held.key !== key) held = { key, target: null, switched: false };
    if (held.target !== null && !clear(held.target)) held.target = null;
    // (Thrown clearly to the other side of a barrier's lane after all, by a corner or the
    // wind?  Then a spot on that side instead -- once, so that the advice cannot see-saw.)
    const beyond = (p) => lanes.some((l) => (x < l - 12 && l < p) || (p < l && l + 12 < x));
    if (held.target !== null && !held.switched && beyond(held.target) && SPOTS.some((p) => clear(p) && !beyond(p))) {
      held.target = SPOTS.filter((p) => clear(p) && !beyond(p)).sort((p, q) => Math.abs(p - x) - Math.abs(q - x))[0];
      held.switched = true;
    }
    // (A sharp corner on the way there throws the car to its outside, whatever it does: then
    // the clear spot furthest out that way, where the car is going to be anyway.)
    const bendOnWay = [0, 1, 2].map((k) => bendAt((car >> 8) + k)).find((b) => Math.abs(b) >= 16);
    if (held.target === null && !(clear(x) && clear(at))) {
      const across = (p) => lanes.some((l) => (at < l && l < p) || (p < l && l < at));
      const ok = SPOTS.filter(clear), near = (list) => list.slice().sort((p, q) => Math.abs(p - at) - Math.abs(q - at))[0];
      held.target = bendOnWay !== undefined ? (bendOnWay > 0 ? ok[0] : ok[ok.length - 1]) : near(ok.filter((p) => !across(p))) ?? near(ok);
    }
    danger = true;
    if (held.target !== null) { target = held.target; why = "a barrier ahead"; }
    else target = x;                                                            // (clear, and staying clear: hold the line)
  } else held = { key: "", target: null, switched: false };
  let wish = null;                                                             // a nice-to-have: pad, recharge, tunnel
  for (const o of objs) {
    if (o.kind >= 1 && o.kind <= 4) continue;
    if (o.kind === 5 || o.kind === 6 || o.kind === 11 || o.kind === 12) {
      // dirt, or a ramp: a ramp throws a sliding car off the edge, so keep off it
      // (or take it dead straight, near its inner side, for its push)
      const left = o.kind === 5 || o.kind === 11, onIt = left ? x < 10 : x > -10, what = o.kind <= 6 ? "dirt" : "a ramp (take it straight or not at all)";
      if (!danger && onIt) { target = left ? 22 : -22; why = `${what} on the ${left ? "left" : "right"}`; danger = true; }
      else if (!danger) { target = x; danger = true; }
    } else if ((o.kind === 9 || o.kind === 10) && health < 48) wish = wish || { target: o.kind === 9 ? -24 : 24, why: "a recharge patch: slow over it for more", dist: o.dist };
    else if (o.kind === 7 || o.kind === 8) wish = wish || { target: o.kind === 7 ? -28 : 28, why: "a boost pad: its middle", dist: o.dist };
    else if (o.kind === 0) wish = wish || { target: -24, why: "the tunnel: a short cut", dist: o.dist };
  }
  // (out of a corner, or close enough that it is now or never: a pad just past a corner)
  if (!danger && wish && (Math.abs(here) <= 2 || wish.dist < PLAYER_Z + 400)) ({ target, why } = wish);
  const off = target - x, steer = Math.abs(off) > 6 ? Math.sign(off) : 0;
  told = target;

  // --- a boost on a clear straight
  const straight = [0, 1, 2].every((k) => Math.abs(bendAt((ahead >> 8) + k)) < 3);
  if (act === "gas" && rd(sym.hBoosts) && !rd(sym.hBoost) && straight && speed > 7.6 && !danger) act = "boost";
  if (act === "lift" && rd(sym.hDirt)) act = "gas";                             // (in the dirt: it slows you anyway)
  return { act, corner, steer, why: steer ? why : "", target, x, speed };
}

// --- on the page ---------------------------------------------------------------------------

const WORDS = {
  keys:  { brake: "BRAKE  Z", lift: "LET GO OF GAS (X)", gas: "GAS  X", boost: "BOOST  ↑", ready: "HOLD GAS (X) FOR THE START", left: "◀ STEER LEFT", right: "STEER RIGHT ▶" },
  touch: { brake: "BRAKE", lift: "LET GO OF GAS", gas: "GAS", boost: "BOOST", ready: "HOLD GAS FOR THE START", left: "◀ STEER LEFT", right: "STEER RIGHT ▶" },
};

// canvas: the screen; buttons: { gas, brake, boost, stick } (elements to light); touch: wording.
export function createGuide({ canvas, buttons, touch = false }) {
  const box = document.createElement("div");
  box.id = "guide";
  box.innerHTML = '<div class="act"></div><div class="steer"></div><div class="why"></div>';
  document.body.appendChild(box);
  const [actEl, steerEl, whyEl] = box.children, words = touch ? WORDS.touch : WORDS.keys;
  let on = false, shown = { act: "", steer: 0 }, pending = null, since = 0, steerSince = 0, steerPending = 0;
  const light = (el, cls, yes) => el && el.classList.toggle(cls, !!yes);
  function clear() {
    box.hidden = true;
    for (const el of Object.values(buttons)) if (el) el.classList.remove("cue", "cue-off", "cue-left", "cue-right");
  }
  clear();
  return {
    get on() { return on; },
    set on(v) { on = !!v; if (!on) clear(); },
    // Once a frame: advice is { act, steer, why } from advise(), or null outside a race.
    show(advice, now = performance.now()) {
      if (!on || !advice || advice.act === "done") { if (!box.hidden) clear(); return; }
      // Keep a cue up a little while (a brake shows at once), so that it does not flicker.
      const a = advice.act;
      if (a !== shown.act) {
        if (pending !== a) { pending = a; since = now; }
        if (a === "brake" || a === "ready" || now - since > 120) shown.act = a;
      } else pending = null;
      if (advice.steer !== shown.steer) {
        if (steerPending !== advice.steer) { steerPending = advice.steer; steerSince = now; }
        if (now - steerSince > 90) shown.steer = advice.steer;
      }
      const r = canvas.getBoundingClientRect();
      box.style.left = r.left + scrollX + "px";
      box.style.top = r.top + scrollY + r.height * 0.04 + "px";
      box.style.width = r.width + "px";
      box.style.fontSize = Math.max(11, Math.min(22, r.width / 24)) + "px";
      box.hidden = false;
      box.dataset.act = shown.act;
      actEl.textContent = words[shown.act] || "";
      steerEl.textContent = shown.steer < 0 ? words.left : shown.steer > 0 ? words.right : "";
      whyEl.textContent = shown.steer ? advice.why || "" : shown.act === "lift" ? "coast: the car grips the corner" : shown.act === "brake" ? "too fast for the corner" : "";
      light(buttons.brake, "cue", shown.act === "brake");
      light(buttons.gas, "cue", shown.act === "gas" || shown.act === "ready");
      light(buttons.gas, "cue-off", shown.act === "lift" || shown.act === "brake");
      light(buttons.boost, "cue", shown.act === "boost");
      light(buttons.stick, "cue-left", shown.steer < 0);
      light(buttons.stick, "cue-right", shown.steer > 0);
    },
  };
}

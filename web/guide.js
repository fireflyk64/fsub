// The guide: reads the race out of the Game Boy's memory and says what to press, a moment
// before it is needed, so that somebody new to the game learns where to brake.
//
// advise(rd, sym) looks at the car (speed, where it is on the road and where it points), the
// course ahead (the bend of each chunk, as the game itself holds it) and what is on the road
// (the two object slots), and works out what a good driver does LEAD frames from now -- about
// the time a person takes to act on what they are told.  The driving is F-Zero's
// (tools/gen_physics.py, tools/FZERO_DYNAMICS.md):
//   * speed: BRAKE, GAS, or BOOST on a clear straight.  A corner is taken no faster than the
//     car can turn to follow it: its turning at full lock (F-Zero's factor for the speed, times
//     the car's own: the game's wTurnTab) against the road's turn under it.  Brake when the
//     brakes (F-Zero's, a twentieth of a unit a frame) need the road from here to get down to
//     that by the corner.  (Off the gas the car neither slows nor grips: it drifts.)
//   * steering: out of a barrier's lane, off the dirt, onto a boost pad or a ramp's middle,
//     over a recharge patch when hurt, onto the inside of a corner (the short way round).  As
//     F-Zero's car turns: the d-pad swings where it points, and the turn carries on a moment
//     after it is let go; so the advice points the car at the spot, and lets go as it gets
//     there, rather than steering until it is there.
// The numbers are fzero.asm's (PLAYER_Z, PATCH_X, the lanes); the places in memory come from
// fsub.sym.  tools/playtest.js has a "guided" bot that does what the guide says, a person's
// reaction late, to check that following it gets round.
//
// createGuide(...) shows the advice over the top of the screen, and lights the touch
// buttons it is about.

const PLAYER_Z = 175;                            // the car is this far ahead of the camera
const STEP = 2 * Math.PI / 192;                  // an angle step (F-Zero's: 192 to a turn)
const BRAKING = 13 / 256;                        // BrakeTab near the top speed: speed lost a frame
const LANES = [-54, -18, 18, 54];                // barrier lanes, kinds 1-4 (a hit within 13 pixels)
const SPOTS = [-60, -36, 0, 36, 60];             // where to be to miss them (18 or more pixels off)
const PATCH = 18, PATCH_HALF = 24;               // dirt, pads, recharge and ramps: their middle either side
const GRAVITY = 3 / 256, DIVE = 16 / 256;        // the fall a frame, in pixels of height: level, and nose down (Up)
let held = { key: "", target: null };            // the spot chosen for the barriers in view
let told = null;                                 // where the last advice sent the car
let ramp = { key: "", go: false };               // the ramp in view, and whether to line up for it (decided once)
let lastFace = 0, lastX = 0;                     // where the car pointed last frame, against the road, and where it was
export const LEAD = 20;                          // frames: how far ahead of the car the advice looks

export function advise(rd, sym, lead = LEAD) {
  if (rd(sym.hMenu)) { told = null; ramp = { key: "", go: false }; return null; }
  const state = rd(sym.hState);
  if (state) { told = null; return { act: "done" }; }
  if (rd(sym.hCount)) { told = null; return { act: "ready" }; }
  const s8 = (v) => (v << 24) >> 24, s16 = (v) => (v << 16) >> 16;
  const speed = (rd(sym.hSpeed) | rd(sym.hSpeed + 1) << 8) / 256;
  const pos = rd(sym.hPos + 1) | rd(sym.hPos + 2) << 8;
  const x = s16(rd(sym.hX) | rd(sym.hX + 1) << 8) / 256, health = rd(sym.hHealth);
  const face = sym.wFacing === undefined ? 0 : s16(rd(sym.wFacing) | rd(sym.wFacing + 1) << 8) / 256;
  const bends = rd(sym.hTunnel) ? sym.wTunnelBend : sym.wTrackBend;
  const bendAt = (c) => (rd(bends + (c & 63)) & 127) - 32;
  const car = pos + PLAYER_Z, ahead = car + speed * lead;

  // --- speed: a bend: slow in, fast out.  The faster the car, the further out a bend's first
  // half keeps it (fzero.asm NarrowTab), and its inside is the short way round, by a lot; braking
  // into it charges a boost that goes off back on the gas.  So: BRAKE as a bend comes, to the
  // speed that lets the car in (5.5 in a hairpin, 6.5 in a gentle one); COAST round the inside
  // (the charge keeps); and from half way, where speed no longer holds the car out, the GAS.
  let act = "gas", corner = 0, chargeWhy = "", half = 0;   // (half: 1 the first, 2 the second, of the bend the car is in)
  const raw = (c) => rd(bends + (c & 63)), cNow = car >> 8;
  const apex = (b) => (Math.abs(b) >= 16 ? 5.5 : 6.5);
  if (Math.abs(bendAt(cNow)) > 2) {
    let start = cNow, end = cNow + 1;
    while (start > cNow - 8 && raw(start - 1) === raw(cNow)) start--;
    while (end < cNow + 8 && raw(end) === raw(cNow)) end++;
    half = car < start * 256 + (end - start) * 128 ? 1 : 2;
    corner = bendAt(cNow);
    if (half === 1) {
      if (speed > apex(corner) + 0.2) { act = "brake"; chargeWhy = "slow in: the inside is the short way"; }
      else { act = "coast"; chargeWhy = "coast round the inside (the boost keeps)"; }
    } else chargeWhy = rd(sym.wCharge) ? "fast out: the gas fires the boost" : "";
  } else if (Math.abs(bendAt((car + 64 + speed * lead) >> 8)) > 2 && speed > apex(bendAt((car + 64 + speed * lead) >> 8)) + 0.2) {
    act = "brake"; corner = bendAt((car + 64 + speed * lead) >> 8); chargeWhy = "slow in: the inside is the short way";   // (as it comes: braking in a bend charges the boost)
  }

  // --- steering: where on the road to be, and why
  let target = 0, why = "", danger = false;
  const hold = Math.max(-48, Math.min(48, x));    // (hold the line: here, but never by the rail, where a wind would pin it)
  const here = bendAt(car >> 8) || bendAt((car + 128) >> 8);
  // (a bend's inside is the short way round, by a lot: as far in as the speed lets the car, the
  // whole way once slow enough, and any speed in its second half)
  if (Math.abs(here) > 2) { target = here > 0 ? 62 : -62; why = "the inside: the short way round"; }   // (the car is held out at the line its speed allows: no harm in aiming further)
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
    const vx = s8(rd(sym.hVX)) / 16, at = Math.max(-60, Math.min(60, told ?? x + vx * 12));
    if (held.key !== key) held = { key, target: null };
    if (held.target !== null && !clear(held.target)) held.target = null;
    if (held.target === null) {
      // (in the way, or heading into it: the nearest clear spot not across a barrier's lane;
      // clear already: the clear spot nearest, to keep to -- a spot, not wherever the car is,
      // which a crosswind would carry into the rail)
      const across = (p) => lanes.some((l) => (at < l && l < p) || (p < l && l < at));
      const ok = SPOTS.filter(clear), near = (list) => list.slice().sort((p, q) => Math.abs(p - at) - Math.abs(q - at))[0];
      held.target = clear(x) && clear(at) ? near(ok) : near(ok.filter((p) => !across(p))) ?? near(ok);
      held.why = clear(x) && clear(at) ? "" : "a barrier ahead";
    }
    danger = true;
    target = held.target; why = held.why;
  } else held = { key: "", target: null };
  let wish = null;                                                             // a nice-to-have: pad, recharge, tunnel
  for (const o of objs) {
    if (o.kind >= 1 && o.kind <= 4) continue;
    const middle = o.kind % 2 ? -PATCH : PATCH;                               // (patches: odd kinds on the left)
    if (o.kind === 5 || o.kind === 6) {
      const onIt = Math.abs(x - middle) <= PATCH_HALF + 6;
      if (!danger && onIt) { target = middle < 0 ? middle + PATCH_HALF + 16 : middle - PATCH_HALF - 16; why = `dirt on the ${middle < 0 ? "left" : "right"}`; danger = true; }
      else if (!danger) { target = hold; danger = true; }
    } else if (o.kind === 11 || o.kind === 12) {
      // A ramp: a jump and a full boost, taken straight on its middle (a slide carries on in
      // the air and can take the car over the rail).  Only if there is time to get there and
      // straighten up first; decided once, when it comes into view, and held.
      const frames = (o.dist - PLAYER_Z) / Math.max(speed, 1);
      const key = `${o.kind}:${((pos + o.dist) >> 8) & 63}`;
      if (ramp.key !== key) ramp = { key, go: Math.abs(x - middle) <= 12 || frames > Math.abs(x - middle) / 2 + 60 };
      // (once on its line, hold it: dead straight, the facing along the road; homing in on its
      // very middle would only arrive at an angle, and the air carries an angle off the road)
      if (ramp.go) { if (!danger) { target = Math.abs(x - middle) <= PATCH_HALF - 8 ? x : middle; why = "a jump ramp: straight onto it"; danger = true; } }
      else if (!danger && Math.abs(x - middle) < PATCH_HALF + 6) { target = middle < 0 ? middle + PATCH_HALF + 16 : middle - PATCH_HALF - 16; why = "a ramp you cannot line up for: keep off it"; danger = true; }
    } else if ((o.kind === 9 || o.kind === 10) && health < 48) wish = wish || { target: middle, why: "a recharge patch: slow over it for more", dist: o.dist };
    else if (o.kind === 7 || o.kind === 8) wish = wish || { target: middle, why: "a boost pad: its middle", dist: o.dist };
    else if (o.kind === 0) wish = wish || { target: -36, why: "the tunnel: a short cut", dist: o.dist };
  }
  // (out of a corner, or close enough that it is now or never: a pad just past a corner)
  if (!danger && wish && (Math.abs(here) <= 2 || wish.dist < PLAYER_Z + 400)) ({ target, why } = wish);
  // Point the car at the spot (a step of its facing for each 6 pixels to go, up to 6): steer
  // while it points short of that, let go as it gets there.  As things will be when the advice
  // is acted on, LEAD frames from now: the car on across the road the way it is going, and its
  // facing swung on by the turn under way (which dies away as the d-pad is let go: half of it).
  const swing = face - lastFace, vx = Math.abs(x - lastX) < 8 ? x - lastX : 0;   // (how fast it is crossing the road: a wind's push too)
  lastFace = face; lastX = x;
  const xThen = x + vx * lead, faceThen = face + swing * lead / 2;
  const want = Math.max(-12, Math.min(12, (target - xThen) / 4)), err = want - faceThen;
  const steer = Math.abs(err) > 1.5 ? Math.sign(err) : 0;
  told = target;

  // --- in the air: nose down (Up) to come down before a bend, or the road turns under the car
  // while it flies on straight and it lands off the side; else nose up (Down) for a soft landing.
  // (F-Zero's: Mute City II's jump runs into a bend.)
  if (rd(sym.hAir)) {
    const z = (rd(sym.hZ) | rd(sym.hZ + 1) << 8) / 256, vz = s16(rd(sym.hVZ) | rd(sym.hVZ + 1) << 8) / 256;
    const flight = (vz + Math.sqrt(vz * vz + 2 * GRAVITY * z)) / GRAVITY;   // frames, level
    let runway = 99999;
    for (let c = (car >> 8) + 1; c < (car >> 8) + 8; c++) if (Math.abs(bendAt(c)) > 2) { runway = c * 256 - car; break; }
    act = flight * speed + 40 > runway ? "dive" : "level";
    return { act, corner, steer: 0, why: "", actWhy: act === "dive" ? "a bend where you would land: come down now" : "land it gently", target: x, x, speed };
  }

  // --- a boost on a clear straight
  const straight = [0, 1, 2].every((k) => Math.abs(bendAt((ahead >> 8) + k)) < 3);
  if (act === "gas" && rd(sym.hBoosts) && !rd(sym.hBoost) && straight && speed > 7 && !danger) act = "boost";
  // --- the pit: low on health, brake down to a crawl over the recharge patches for the most
  // (fzero.asm HEAL_CRAWL: about 60% of what is missing over both; flat out, a third)
  let actWhy = chargeWhy;
  if (health < 40) for (const o of objs) {
    if (o.kind !== 9 && o.kind !== 10) continue;
    const d = o.dist - PLAYER_Z - speed * lead;
    if (speed > 3.5 && d < (speed * speed - 9) / (2 * BRAKING) + speed * 8) { act = "brake"; actWhy = "crawl over the recharge: it gives the most"; }
  }
  return { act, corner, steer, why: steer ? why : "", actWhy, target, x, speed };
}

// --- on the page ---------------------------------------------------------------------------

const WORDS = {
  keys:  { brake: "BRAKE  Z", coast: "COAST (LET GO)", gas: "GAS  X", boost: "BOOST  ↑", dive: "NOSE DOWN  ↑", level: "NOSE UP  ↓", ready: "HOLD GAS (X) FOR THE START", left: "◀ STEER LEFT", right: "STEER RIGHT ▶" },
  touch: { brake: "BRAKE", coast: "COAST (LET GO)", gas: "GAS", boost: "BOOST", dive: "NOSE DOWN", level: "NOSE UP", ready: "HOLD GAS FOR THE START", left: "◀ STEER LEFT", right: "STEER RIGHT ▶" },
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
      whyEl.textContent = shown.steer ? advice.why || "" : advice.actWhy ? advice.actWhy : shown.act === "brake" ? "too fast for the corner" : "";
      light(buttons.brake, "cue", shown.act === "brake");
      light(buttons.gas, "cue", shown.act === "gas" || shown.act === "ready");
      light(buttons.gas, "cue-off", shown.act === "brake" || shown.act === "coast");
      light(buttons.boost, "cue", shown.act === "boost" || shown.act === "dive");
      light(buttons.stick, "cue-left", shown.steer < 0);
      light(buttons.stick, "cue-right", shown.steer > 0);
    },
  };
}

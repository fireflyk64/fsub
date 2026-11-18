// The link cable between two browsers.
//
// fsub's two-player mode (fzero.asm, "Link cable") was made for two consoles
// and a cable: whoever presses Start calls ($AA), a console waiting in link
// mode answers ($55), and from then on the caller clocks 9-byte packets (a
// sync byte with bit 7 set, the player's position, one of its rivals, a
// checksum) one byte at a time, swapping each with the byte the other
// console has ready.  Each console runs its own race and only shows the
// other's cars where the newest packet put them, so a packet late or lost
// costs nothing but a frame of the other car's place.
//
// Over a network a byte cannot wait for the other browser (a round trip is
// several frames; a packet is 9 bytes), so each page plays the other console
// for its own Game Boy, from the packets the other page sends:
//   * Ours clocks (the caller, "master"): each byte it sends is answered at
//     once with the matching byte of the newest packet from the other page,
//     lined up on the sync byte as a real cable lines them up.
//   * Ours answers ("slave"): the page clocks it, a byte every ~3 ms of
//     emulated time as the real caller does, with the other page's packets.
//   * Either way, the bytes ours sends make up its packets, which go to the
//     other page as they are completed.
// Only the call waits for the other page: the calling Game Boy's transfer is
// held (the emulator's link hooks allow that) until the other page says its
// Game Boy took the call.  A Game Boy that leaves the race drops the link on
// both pages, as pulling the cable would.
//
// The emulator side is binjgb with the link-cable hooks (tools/binjgb/);
// the transport is anything with send(bytes, reliable), here a two-seat
// lobbylink room (web/lobby.js).  Nothing here touches the page, so
// tools/netlink-test.mjs runs two Game Boys through it in Node (tools/linktest.c
// is the ROM's own test: two SameBoy cores on a plain emulated cable).

export const EV_SERIAL = 0x20;
export const INFO_MENU = 8, INFO_ALONE = 16;   // info(): in the menu; racing, not in link mode
const CALL = 0xaa, ANSWER = 0x55, NOBODY = 0xff;
const N = 9;                       // bytes in a packet
const CLOCK_TICKS = 12288;         // ~2.9 ms between the bytes we clock in (the ROM's 2 ms gap plus the byte)
const CALL_WAIT_MS = 3000;         // a call nobody takes is answered with nobody
const ACCEPT_WAIT_MS = 1000;       // how long a call waits for our Game Boy to be listening
const STALE_MS = 4000;             // no packet for this long: the link is gone (the ROM gives up after 3 s)
const QUIET_MS = 1000;             // our Game Boy stopped using the cable for this long: it left the link
const STATUS_MS = 1000;
const MAX_QUEUE = 3;               // packets kept for our Game Boy; older ones are dropped (latency over completeness)

// Wire messages, first byte: a packet (best effort; seq u16), or control (reliable).
const M_PACKET = 0x50, M_STATUS = 0x53, M_CALL = 0x43, M_ACCEPT = 0x41, M_REFUSE = 0x4e, M_BYE = 0x42;
export const WIRE = { M_PACKET, M_STATUS, M_CALL, M_ACCEPT, M_REFUSE, M_BYE };   // (for a far end that is not a page: ghost.js)

export class Cable {
  // m, e: the binjgb module and emulator.  send(bytes, reliable): to the other page.
  // now(): milliseconds.  on(event, detail): "state" when the link's state changes,
  // "peer" when the other page's status changes.  info(): where our Game Boy is, for the
  // other page to tell its player: INFO_MENU | INFO_ALONE (racing, not in link mode).
  constructor({ m, e, send, now = () => performance.now(), on = () => {}, info = () => 0, log = () => {} }) {
    Object.assign(this, { m, e, send, now, on, info, log });
    this.plugged = false;
    this.lower = false;            // our seat is the lower: we win a call made by both at once
    this.host = false;             // our player hosts: our page makes the call (our track and rivals count)
    this.reset();
  }

  reset() {
    this.role = null;              // "master" | "slave" | null
    this.calling = 0;              // when our Game Boy's call went out (0: no call)
    this.incoming = 0;             // when the other page's call came (0: none)
    this.queue = [];               // their packets, oldest first
    this.cur = null; this.idx = N; // the packet being clocked / answered, and where in it
    this.asm = null;               // our Game Boy's packet being put together
    this.seqOut = 0; this.seqIn = -1;
    this.lastRx = 0; this.lastUse = 0; this.nextClock = 0;
    this.peer = { listening: false, linked: false, calling: false, menu: false, alone: false };
    this.statusAt = 0; this.statusSent = -1;
    this.stats = { tx: 0, rx: 0, late: 0 };
  }

  get state() { return !this.plugged ? "unplugged" : this.role || (this.calling ? "calling" : "waiting"); }
  ticks() { return this.m._emulator_get_ticks_f64(this.e); }
  reg(addr) { return this.m._emulator_read_mem(this.e, addr); }
  // Our Game Boy waits for a link: link mode, no partner, $55 loaded, the external clock armed.
  listening() { return this.role === null && (this.reg(0xff02) & 0x81) === 0x80 && this.reg(0xff01) === ANSWER; }

  // Should the page press Start for its player?  Both Game Boys wait in link mode (2P)
  // and ours is the host's: on a real cable one of the players presses Start to call the
  // other (and that console's track and rivals count); here the host's page does it, so
  // that waiting together is enough.
  autoCall() {
    return this.plugged && this.host && this.role === null && !this.calling && !this.incoming && this.peer.listening && this.listening();
  }

  // The other page is there (lower: our seat is the lower one; host: our player hosts).
  plug(lower, host = lower) {
    if (this.plugged) return;
    this.reset();
    this.plugged = true; this.lower = !!lower; this.host = !!host;
    this.m._emulator_set_serial_link(this.e, 1);
    this.changed();
  }
  unplug() {
    if (!this.plugged) return;
    this.plugged = false;
    this.m._emulator_set_serial_link(this.e, 0);   // (answers a waiting transfer with nobody)
    this.reset();
    this.changed();
  }

  changed() { this.on("state", this.state); this.status(true); }
  ctl(type, ...rest) { try { this.send(Uint8Array.of(type, ...rest), true); } catch (err) { this.log("link: " + err); } }
  status(force) {
    if (!this.plugged) return;
    const s = (this.listening() ? 1 : 0) | (this.role ? 2 : 0) | (this.calling ? 4 : 0) | (this.info() & (INFO_MENU | INFO_ALONE));
    const t = this.now();
    if (!force && s === this.statusSent && t - this.statusAt < STATUS_MS) return;
    this.statusSent = s; this.statusAt = t;
    this.ctl(M_STATUS, s);
  }

  // The link is over (say: tell the other page).  Our Game Boy notices by itself:
  // it gets no more good packets and gives up after 3 s, as with a pulled cable.
  drop(say, why) {
    if (!this.role && !this.calling) return;
    this.log(`link: dropped (${why})`);
    if (this.calling) this.answerCall(NOBODY);
    this.role = null; this.queue = []; this.cur = null; this.asm = null; this.incoming = 0;
    if (say) this.ctl(M_BYE);
    this.changed();
  }

  answerCall(byte) {
    this.calling = 0;
    this.m._emulator_serial_complete(this.e, byte);
  }

  // Our Game Boy sent a byte: file it in our packet, and send that when it is whole.
  collect(b) {
    if (b & 0x80) this.asm = [b];
    else if (this.asm) this.asm.push(b);
    if (this.asm && this.asm.length === N) {
      const seq = this.seqOut = (this.seqOut + 1) & 0xffff;
      try { this.send(Uint8Array.of(M_PACKET, seq >> 8, seq & 0xff, ...this.asm), false); this.stats.tx++; } catch (err) { /* a lost packet */ }
      this.asm = null;
    }
  }
  // The other Game Boy's byte for this exchange, lined up on our sync byte: from the
  // oldest packet queued, or, with none, zeros (which add up to nothing).
  theirByte(start) {
    if (start || this.idx >= N) { this.cur = this.queue.shift() || null; this.idx = 0; }
    const b = this.cur ? this.cur[this.idx] : 0;
    this.idx++;
    return b;
  }

  // emulator_run_until returned EV_SERIAL: our Game Boy clocked a byte and waits for the answer.
  serial() {
    const out = this.m._emulator_get_serial_out(this.e);
    if (out < 0) return;
    const t = this.now();
    if (this.role === "master") {
      this.lastUse = t;
      this.collect(out);
      this.m._emulator_serial_complete(this.e, this.theirByte((out & 0x80) !== 0));
      return;
    }
    if (out === CALL && this.role === null) {          // Start pressed in link mode: call the other page
      if (this.calling) return;
      if (this.incoming) {                             // they are calling us already: the lower seat's call stands
        if (!this.lower) { this.answerCall(NOBODY); return; }
        this.incoming = 0;
      }
      this.calling = t;
      this.ctl(M_CALL);
      this.changed();
      return;                                          // the transfer waits for their answer
    }
    // Anything else (our Game Boy thinks it is linked and we do not): nothing that adds up.
    this.m._emulator_serial_complete(this.e, 0);
  }

  // From the other page.
  receive(data) {
    const d = data instanceof Uint8Array ? data : new Uint8Array(data);
    if (!d.length || !this.plugged) return;
    const t = this.now();
    switch (d[0]) {
      case M_PACKET: {
        if (d.length !== 3 + N || !this.role) return;
        const seq = d[1] << 8 | d[2];
        // (Best effort is unordered: an older packet would put a car back, or restart the race.)
        if (this.seqIn >= 0 && ((seq - this.seqIn) & 0xffff) >= 0x8000) { this.stats.late++; return; }
        this.seqIn = seq; this.lastRx = t; this.stats.rx++;
        this.queue.push(d.slice(3));
        if (this.queue.length > MAX_QUEUE) this.queue.splice(0, this.queue.length - MAX_QUEUE);
        return;
      }
      case M_STATUS: {
        const peer = { listening: !!(d[1] & 1), linked: !!(d[1] & 2), calling: !!(d[1] & 4), menu: !!(d[1] & INFO_MENU), alone: !!(d[1] & INFO_ALONE) };
        const was = this.peer;
        this.peer = peer;
        if (Object.keys(peer).some((k) => peer[k] !== was[k])) this.on("peer", peer);
        return;
      }
      case M_CALL:
        if (this.role) this.drop(false, "they called again");
        if (this.calling) {
          if (this.lower) return;                      // both called: the lower seat's call stands
          this.answerCall(NOBODY);                     // ours gives way; our Game Boy listens again and takes theirs
        }
        this.incoming = t;
        return;
      case M_ACCEPT:
        if (!this.calling) { this.ctl(M_BYE); return; } // (our Game Boy gave up meanwhile)
        this.answerCall(ANSWER);
        this.role = "master"; this.lastRx = this.lastUse = t;
        this.log("link: linked, our Game Boy clocks");
        this.changed();
        return;
      case M_REFUSE:
        if (this.calling) { this.answerCall(NOBODY); this.changed(); }
        return;
      case M_BYE:
        this.drop(false, "the other Game Boy left the link");
        return;
    }
  }

  // Between slices of emulation (every ~3 ms of emulated time while plugged in).
  tick() {
    if (!this.plugged) return;
    const t = this.now();
    if (this.calling && t - this.calling > CALL_WAIT_MS) { this.log("link: nobody took the call"); this.answerCall(NOBODY); this.changed(); }
    if (this.incoming) {
      if (this.listening()) {                          // take their call: our Game Boy answers to their clock
        const out = this.m._emulator_serial_external(this.e, CALL);
        this.incoming = 0;
        if (out === ANSWER) {
          this.role = "slave"; this.lastRx = this.lastUse = t; this.nextClock = this.ticks() + CLOCK_TICKS;
          this.ctl(M_ACCEPT);
          this.log("link: linked, the other Game Boy clocks");
          this.changed();
        } else this.ctl(M_REFUSE);
      } else if (t - this.incoming > ACCEPT_WAIT_MS) { this.incoming = 0; this.ctl(M_REFUSE); }
    }
    // Clock the next byte in, once our Game Boy is ready for it (it re-arms after filing each).
    if (this.role === "slave" && this.ticks() >= this.nextClock && (this.reg(0xff02) & 0x81) === 0x80) {
      const out = this.m._emulator_serial_external(this.e, this.theirByte(false));
      if (out >= 0) { this.lastUse = t; this.collect(out); this.nextClock = this.ticks() + CLOCK_TICKS; }
    }
    if (this.role && t - this.lastRx > STALE_MS) this.drop(true, "no packets from the other page");
    else if (this.role && t - this.lastUse > QUIET_MS) this.drop(true, "our Game Boy left the link");
    this.status(false);
  }
}

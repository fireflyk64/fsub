// The lobby beside the player: a chat room where racers find each other, and
// the two-seat rooms their races are linked through.
//
// The lobby is one room of the lobbylink server (FSUB-LOBBY; when it is full,
// FSUB-LOBBY0, FSUB-LOBBY1, ...) whose chat goes from browser to browser; the
// server only introduces the browsers to each other.  Its connection is the
// dosbox page's public lobby's (the site's dosbox/hall.js,
// "HallNet" below, copied with its notes): browsers link directly, and
// through the server's TURN relay only when that fails, because the relay
// has ports for a few dozen links and the races need them; a seat whose page
// went away without leaving can be claimed after two and a half minutes;
// every page says something to the server once in a while so that its own
// seat is not taken.
//
// A race is a room of two seats with a code of its own (FSUB-K7Q2XM): "Race"
// next to a racer's name asks them, and when they say yes both pages join
// it; "Invite a friend" makes one and gives a link (?race=CODE) that brings
// whoever opens it into it.  Its connection is lobbylink's own client
// (p2p-client.js), with the relay from the start, and it carries the link
// cable (web/link.js) between the two Game Boys.  Everybody in a race stays
// in the lobby and can go on chatting.
//
// Playing alone is the page's default and needs none of this: nothing
// connects to the lobby server until the player opens the lobby (open()), or
// arrives with a race link.
//
// Lobby messages (JSON text on the lobby's channel):
//   {t: "hello", name, busy, reply}   who this is; busy: "" or the name of whom they race
//   {t: "chat", text}                 a line (checked on both ends: web/chatfilter.js)
//   {t: "ask", code}                  "race me?" and the room for it
//   {t: "yes", code} / {t: "no", code} / {t: "drop", code}   the answer, or the question taken back
import { P2PGame } from "./p2p-client.js";
import { checkMessage, checkName, pickCallsign, makeBucket, lineEvery, whyText, MAX_CHARS, MAX_NAME } from "./chatfilter.js";

export const LOBBY_SERVER = "https://pqrstuvw.xyz/lobbylink";
const LOBBY_CODE = "FSUB-LOBBY";
const lobbyCode = (n, base = LOBBY_CODE) => (n <= 0 ? base : base + (n - 1));

const SEATS = 32;                 // asked for (what the public server gives a room; 32 racers at a line every ten seconds are three lines a second); a server that gives fewer says how many
const CLAIM_SEATS = 256;          // a full lobby is asked for seats up to here: another page may have made it bigger
const LOBBIES = 32;               // FSUB-LOBBY, FSUB-LOBBY0 ... FSUB-LOBBY30: how far a page goes for a seat
const CLAIM_BATCH = 32;           // seats of a full lobby asked for in one go
const OFFER_SPREAD_MS = 25;       // per racer in the lobby: over how long the offers to a newcomer are spread
const OFFER_SPREAD_MAX_MS = 6000;
const CLAIM_AFTER_MS = 150000;
const HEARTBEAT_MS = 25000;
const CONNECT_TIMEOUT_MS = 20000;
const DIRECT_WAIT_MS = 12000;     // how long a direct connection gets before the relay is tried
const RELAY_WAIT_MS = 30000;
const MAX_ATTEMPTS = 3;           // per pair: direct, relayed, relayed

// -- the connection (HallNet, from the dosbox page) ------------------------------

function signalingUrl(server) {
  const u = new URL(server);
  if (u.protocol === "http:") u.protocol = "ws:";
  else if (u.protocol === "https:") u.protocol = "wss:";
  else if (u.protocol !== "ws:" && u.protocol !== "wss:") throw new Error(`unsupported scheme ${u.protocol} in the lobby server's address`);
  let path = u.pathname.replace(/\/+$/, "");
  if (!path.endsWith("/ws")) path += "/ws";
  u.pathname = path; u.search = ""; u.hash = "";
  return u.toString();
}
const fail = (code, message) => Object.assign(new Error(message), { code });
// The lobby server did not answer (these are the lobbylink client's codes
// too), and what a racer is told then: no page depends on that one server.
const serverDown = (code) => ["connection-failed", "connection-closed", "connection-lost", "connect-timeout", "invalid-server-url"].includes(code);
const shuffled = (n) => { const a = Array.from({ length: n }, (_, i) => i); for (let i = n - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };

// One seat in the room and a data channel to everybody else in it.
//   on.roster()            somebody came or went
//   on.link(id, open)      the channel to a racer opened or closed
//   on.message(id, text)   a message from a racer
//   on.lost(code, message) the seat is gone (the room ended, the seat was taken, the server went away)
class HallNet {
  // code: the first lobby's; the others are code + "0", code + "1", ...
  constructor({ server, code, lobbies = LOBBIES, seats = SEATS, claimAfterMs = CLAIM_AFTER_MS, heartbeatMs = HEARTBEAT_MS, on, log }) {
    Object.assign(this, { server, base: code, code, lobbies, seats, claimAfterMs, heartbeatMs, on, log });
    this.ws = null; this.selfId = -1; this.maxPlayers = 0; this.players = []; this.token = "";
    this.links = new Map(); this.soon = new Map(); this.closed = false; this.beat = null; this.iceAll = []; this.iceDirect = [];
  }

  // Takes a seat: the one this page had (its token), or a seat in the first
  // lobby of the row that has one -- a free seat, or, when all are taken,
  // the seat of a racer who has been silent too long.
  connect() {
    const url = signalingUrl(this.server);
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      let waiting = null, settled = false;
      const done = (err, joined) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        // (The page left while the server was answering: the seat goes back.)
        if (!err && this.closed) { err = fail("closed", "left the lobby"); try { ws.send('{"type":"leave"}'); } catch (e) { /* gone */ } }
        if (err) { try { ws.close(); } catch (e) { /* gone */ } reject(err); return; }
        this.adopt(ws, joined);
        resolve();
      };
      // (The time is for one round of answers: the row is asked lobby by lobby.)
      let timer = null;
      const arm = () => { clearTimeout(timer); timer = setTimeout(() => done(fail("connect-timeout", "the lobby server did not answer")), CONNECT_TIMEOUT_MS); };
      arm();
      // The server answers every question with "joined" or an error, in
      // order: several can be asked at once.  With a "joined" among the
      // answers the rest are "already joined" and nobody waits for them.
      const askAll = (msgs) => new Promise((answer) => {
        const got = [];
        waiting = (m) => { got.push(m); if (m.type === "joined" || got.length === msgs.length) { waiting = null; answer(got); } };
        arm();
        for (const m of msgs) ws.send(JSON.stringify(m));
      });
      const ask = (msg) => askAll([msg]).then((got) => got[got.length - 1]);
      const create = () => ({ maxPlayers: this.seats, waitUntilFull: false, allowLateJoin: true, allowReconnect: true,
                              allowReplacement: true, reconnectPolicy: "token-or-claim-after-timeout", claimAfterMs: this.claimAfterMs });
      ws.onmessage = (ev) => {
        let m;
        try { m = JSON.parse(ev.data); } catch (e) { return; }
        if (waiting && (m.type === "joined" || m.type === "error")) waiting(m);
      };
      ws.onerror = () => done(fail("connection-failed", "no connection to the lobby server"));
      ws.onclose = () => done(fail("connection-closed", "the lobby server closed the connection"));
      const full = { type: "error", code: "room-full", message: "every seat is taken" };
      const join = (code, token) => ask({ type: "join", code, create: create(), ...(token ? { resumeToken: token } : {}) });
      // A full lobby: the seat of a racer who has been silent too long, if
      // there is one.  (The seats are asked for a batch at a time, in no
      // order; the first answer names how many seats there are.)
      const claim = async (code) => {
        let seats = CLAIM_SEATS;
        const ids = shuffled(CLAIM_SEATS);
        for (let i = 0; i < ids.length; i += CLAIM_BATCH) {
          const batch = ids.slice(i, i + CLAIM_BATCH).filter((id) => id < seats);
          if (!batch.length) continue;
          const answers = await askAll(batch.map((id) => ({ type: "claim-slot", code, playerId: id })));
          const won = answers.find((m) => m.type === "joined");
          if (won) return won;
          for (const m of answers) {
            const range = m.code === "invalid-target" && /out of range 0\.\.(\d+)/.exec(m.message || "");
            if (range) seats = Math.min(seats, Number(range[1]) + 1);
            else if (m.code === "room-not-found") return join(code);   // (it ended meanwhile)
            else if (m.code !== "slot-not-claimable") return full;     // (a room that lets nobody claim)
          }
        }
        return full;
      };
      const seatIn = async (code, token) => {
        let r = await join(code, token);
        // (A server set up with fewer seats to a room says how many.)
        const limit = r.type === "error" && r.code === "invalid-create" && /exceeds limit (\d+)/.exec(r.message || "");
        if (limit && Number(limit[1]) >= 2) { this.seats = Number(limit[1]); r = await join(code, token); }
        return r.type === "error" && r.code === "room-full" ? claim(code) : r;
      };
      ws.onopen = async () => {
        try {
          // The lobby this page was in, while its seat there may still be its own ...
          let r = this.token ? await seatIn(this.code, this.token) : full;
          // ... or the first of the row with a seat.
          for (let n = 0; n < this.lobbies && r.type !== "joined" && r.code === "room-full"; n++) r = await seatIn(lobbyCode(n, this.base), "");
          if (r.type === "joined") done(null, r);
          else done(fail(r.code || "error", r.code === "room-full" ? "every lobby is full" : r.message || "the lobby server refused"));
        } catch (e) { done(fail("connection-failed", String(e && e.message ? e.message : e))); }
      };
    });
  }

  adopt(ws, joined) {
    this.ws = ws;
    this.code = joined.code || this.code;
    this.selfId = joined.selfId; this.maxPlayers = joined.maxPlayers; this.token = joined.resumeToken || "";
    this.players = (joined.players || []).map((p) => ({ id: p.id, occupied: !!p.occupied, connected: !!p.connected }));
    this.iceAll = (joined.iceServers || []).map((s) => ({ urls: s.urls, username: s.username, credential: s.credential }));
    const urls = (s) => (Array.isArray(s.urls) ? s.urls : [s.urls]);
    this.iceDirect = this.iceAll.filter((s) => urls(s).every((u) => /^stuns?:/.test(u)));
    if (!this.iceDirect.length) {
      // (A TURN server answers STUN on the same port.)
      const stun = this.iceAll.flatMap(urls).filter((u) => /^turn:/.test(u)).map((u) => u.replace(/^turn:/, "stun:").replace(/\?.*$/, ""));
      if (stun.length) this.iceDirect = [{ urls: Array.from(new Set(stun)) }];
    }
    ws.onmessage = (ev) => { if (this.ws === ws) { let m; try { m = JSON.parse(ev.data); } catch (e) { return; } this.serverSays(m); } };
    ws.onerror = () => { /* onclose follows */ };
    ws.onclose = () => { if (this.ws === ws && !this.closed) this.lost("connection-lost", "the connection to the lobby server was lost"); };
    this.startHeartbeat();
    // The lower seat offers: to everybody above who is there now; those
    // below offer to us when the server tells them we came.
    for (const [id] of this.links) this.dropLink(id);
    for (const p of this.players) if (p.id > this.selfId && p.occupied && p.connected) this.offerSoon(p.id);
  }

  // An offer after a moment of its own, longer in a fuller lobby, so that
  // the offers a newcomer gets (and the answers to its own) do not all go
  // through the server at once.
  offerSoon(id) {
    clearTimeout(this.soon.get(id));
    const crowd = this.players.filter((p) => p.occupied).length;
    this.soon.set(id, setTimeout(() => {
      this.soon.delete(id);
      const p = this.players[id];
      if (!this.closed && this.ws && p && p.occupied && p.connected && !this.links.has(id)) void this.offer(id, 0);
    }, Math.random() * Math.min(OFFER_SPREAD_MAX_MS, OFFER_SPREAD_MS * crowd)));
  }
  forgetOffers() { for (const t of this.soon.values()) clearTimeout(t); this.soon.clear(); }

  startHeartbeat() {
    this.stopHeartbeat();
    this.beat = setInterval(() => { try { if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.send('{"type":"ping"}'); } catch (e) { /* onclose reports */ } }, this.heartbeatMs);
  }
  stopHeartbeat() { if (this.beat) clearInterval(this.beat); this.beat = null; }

  // The seat is gone, or the socket is: the links to the others stay up
  // unless the server ended the room or gave the seat away.
  lost(code, message) {
    const gone = code === "replaced" || code === "session-superseded" || code === "room-expired";
    this.stopHeartbeat();
    const ws = this.ws;
    this.ws = null;
    try { if (ws) ws.close(); } catch (e) { /* gone */ }
    this.forgetOffers();
    if (gone) { this.token = ""; for (const [id] of this.links) this.dropLink(id); }
    this.on.lost(code, message, gone);
  }

  serverSays(m) {
    const slot = (id) => this.players[id];
    switch (m.type) {
      case "player-joined":
        if (Array.isArray(m.players)) this.players = m.players.map((p) => ({ id: p.id, occupied: !!p.occupied, connected: !!p.connected }));
        this.peerCame(m.playerId);
        break;
      case "player-rejoined": case "player-replaced":
        if (slot(m.playerId)) { slot(m.playerId).occupied = true; slot(m.playerId).connected = true; }
        this.peerCame(m.playerId);
        break;
      case "player-left":
        if (slot(m.playerId)) { slot(m.playerId).connected = false; if (m.reason === "explicit-leave") slot(m.playerId).occupied = false; }
        // (Only its socket to the server may be gone: an open channel stays.)
        if (m.reason === "explicit-leave") { clearTimeout(this.soon.get(m.playerId)); this.soon.delete(m.playerId); this.dropLink(m.playerId); }
        this.on.roster();
        break;
      case "signal":
        void this.signalFrom(m.from, m.payload || {});
        break;
      case "error":
        if (m.code === "invalid-message") break;   // the answer to our sign of life
        if (m.code === "already-joined") break;    // ... and to the seats asked for after the one we got
        if (["replaced", "session-superseded", "room-expired", "slow-consumer"].includes(m.code)) this.lost(m.code, m.message || m.code);
        else this.log(`lobby: the server says ${m.code}: ${m.message}`);
        break;
    }
  }

  peerCame(id) {
    if (id === this.selfId) return;
    this.dropLink(id);
    this.on.roster();
    if (this.selfId < id) this.offerSoon(id);
  }

  signal(to, payload) {
    try { if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify({ type: "signal", to, payload })); } catch (e) { /* onclose reports */ }
  }

  makeLink(id, initiator, relay) {
    this.dropLink(id);
    const pc = new RTCPeerConnection({ iceServers: relay ? this.iceAll : this.iceDirect });
    const dc = pc.createDataChannel("hall", { negotiated: true, id: 1, ordered: true });
    const link = { id, pc, dc, initiator, attempt: 0, open: false, timer: null, pending: [] };
    this.links.set(id, link);
    const current = () => this.links.get(id) === link;
    dc.onopen = () => { if (!current()) return; link.open = true; clearTimeout(link.timer); this.on.link(id, true); };
    dc.onclose = () => { if (!current()) return; const was = link.open; link.open = false; if (was) this.on.link(id, false); };
    dc.onmessage = (ev) => { if (current() && typeof ev.data === "string") this.on.message(id, ev.data); };
    pc.onicecandidate = (ev) => { if (current() && ev.candidate) this.signal(id, { kind: "ice", candidate: ev.candidate.toJSON() }); };
    pc.onconnectionstatechange = () => { if (current() && pc.connectionState === "failed") this.linkFailed(link); };
    return link;
  }
  dropLink(id) {
    const link = this.links.get(id);
    if (!link) return;
    this.links.delete(id);
    clearTimeout(link.timer);
    try { link.dc.close(); } catch (e) { /* closed */ }
    try { link.pc.close(); } catch (e) { /* closed */ }
    if (link.open) { link.open = false; this.on.link(id, false); }
  }

  async offer(id, attempt) {
    if (this.closed) return;
    const link = this.makeLink(id, true, attempt > 0);
    link.attempt = attempt;
    link.timer = setTimeout(() => this.linkFailed(link), attempt > 0 ? RELAY_WAIT_MS : DIRECT_WAIT_MS);
    try {
      const offer = await link.pc.createOffer();
      if (this.links.get(id) !== link) return;
      await link.pc.setLocalDescription(offer);
      if (this.links.get(id) !== link) return;
      this.signal(id, { kind: "offer", sdp: link.pc.localDescription.sdp, relay: attempt > 0 });
    } catch (e) { this.log(`lobby: no offer to racer ${id + 1}: ${e && e.message ? e.message : e}`); }
  }
  // The offering side tries again, the next time with the relay.
  linkFailed(link) {
    if (this.links.get(link.id) !== link || this.closed) return;
    const id = link.id, next = link.attempt + 1, offers = link.initiator;
    this.dropLink(id);
    this.on.roster();
    if (!offers || next >= MAX_ATTEMPTS) return;
    const there = () => !this.closed && this.ws && !this.links.has(id) && this.players[id] && this.players[id].occupied && this.players[id].connected;
    setTimeout(() => { if (there()) void this.offer(id, next); }, 500 * next);
  }

  async signalFrom(from, payload) {
    if (this.closed || from === this.selfId || !Number.isInteger(from)) return;
    try {
      if (payload.kind === "offer") {
        if (this.selfId < from) return;   // (we offer to those above us)
        const link = this.makeLink(from, false, !!payload.relay);
        await link.pc.setRemoteDescription({ type: "offer", sdp: payload.sdp });
        if (this.links.get(from) !== link) return;
        this.flush(link);
        const answer = await link.pc.createAnswer();
        if (this.links.get(from) !== link) return;
        await link.pc.setLocalDescription(answer);
        if (this.links.get(from) !== link) return;
        this.signal(from, { kind: "answer", sdp: link.pc.localDescription.sdp });
      } else if (payload.kind === "answer") {
        const link = this.links.get(from);
        if (!link || link.pc.signalingState !== "have-local-offer") return;
        await link.pc.setRemoteDescription({ type: "answer", sdp: payload.sdp });
        this.flush(link);
      } else if (payload.kind === "ice") {
        const link = this.links.get(from);
        if (!link) return;
        if (link.pending) link.pending.push(payload.candidate);
        else await link.pc.addIceCandidate(payload.candidate || undefined).catch(() => { /* a candidate of an older attempt */ });
      }
    } catch (e) { this.log(`lobby: connecting to racer ${from + 1}: ${e && e.message ? e.message : e}`); }
  }
  flush(link) {
    const queued = link.pending || [];
    link.pending = null;
    for (const c of queued) link.pc.addIceCandidate(c || undefined).catch(() => { /* stale */ });
  }

  open(id) { const l = this.links.get(id); return !!(l && l.open); }
  send(id, text) {
    const l = this.links.get(id);
    if (!l || !l.open) return false;
    try { l.dc.send(text); return true; } catch (e) { return false; }
  }

  // Gives the seat back.
  close() {
    if (this.closed) return;
    this.closed = true;
    this.stopHeartbeat();
    this.forgetOffers();
    const ws = this.ws;
    this.ws = null;
    try { if (ws && ws.readyState === WebSocket.OPEN) ws.send('{"type":"leave"}'); } catch (e) { /* gone */ }
    try { if (ws) ws.close(1000, "left"); } catch (e) { /* gone */ }
    for (const [id] of this.links) this.dropLink(id);
  }
}


// -- a race: a room of two seats, and the link cable through it -------------------

const CODE_CHARS = "BCDFGHJKLMNPQRSTVWXZ23456789";   // no vowels and no 0/1: no words, nothing misread
export const newRaceCode = () => "FSUB-" + Array.from(crypto.getRandomValues(new Uint8Array(6)), (b) => CODE_CHARS[b % CODE_CHARS.length]).join("");
export const isRaceCode = (c) => /^FSUB-[A-Z0-9]{4,12}$/.test(String(c || "")) && !/^FSUB-LOBBY/.test(c);
const META = 0x7b;   // '{': a JSON message between the two pages; anything else is the cable's

// on.change() something to show changed; on.over(why) the race is over.
// host: our player asked for the race (or invited): our page makes the call when both
// Game Boys wait, so our track and rivals count.
class Race {
  constructor({ server, code, cable, name, host, on, log }) {
    Object.assign(this, { server, code, cable, name, host: !!host, on, log });
    this.game = null; this.other = -1; this.left = false;
    this.phase = "joining";        // joining | alone | connecting | connected
    this.otherName = "";
  }
  async join() {
    let game;
    try {
      game = await P2PGame.connect({
        server: this.server, code: this.code,
        create: { maxPlayers: 2, waitUntilFull: false, allowLateJoin: true, allowReconnect: true, allowReplacement: true,
                  reconnectPolicy: "token-or-claim-after-timeout", claimAfterMs: 15000 },
        storageKey: "fsub:race:" + this.code, storage: "session",
      });
    } catch (err) {
      if (this.left) return;
      this.left = true;
      this.on.over(err && err.code === "room-full" ? "that race has two racers already" : `no connection to the lobby server (${(err && (err.code || err.message)) || err})`);
      return;
    }
    if (this.left) { game.close(); return; }
    this.game = game;
    this.other = 1 - game.selfId;
    game.onEvent((ev) => this.event(ev));
    const p = game.players[this.other];
    this.phase = p && p.occupied && p.connected ? "connecting" : "alone";
    this.on.change();
  }
  event(ev) {
    if (this.left) return;
    switch (ev.type) {
      case "message":
        if (ev.from !== this.other) return;
        if (ev.data[0] === META) this.meta(ev.data); else this.cable.receive(ev.data);
        return;
      case "peer-state":
        if (ev.playerId !== this.other) return;
        if (ev.state === "connected") { this.phase = "connected"; this.cable.plug(this.game.selfId < this.other, this.host); this.hello(); }
        else if (ev.state === "failed" || ev.state === "closed") { this.phase = "connecting"; this.cable.unplug(); }
        this.on.change();
        return;
      case "player-joined": case "player-rejoined": case "player-replaced":
        if (ev.playerId === this.other && this.phase !== "connected") { this.phase = "connecting"; this.on.change(); }
        return;
      case "player-left":
        if (ev.playerId !== this.other || ev.reason !== "explicit-leave") return;
        this.cable.unplug(); this.phase = "alone";
        this.log(`race: ${this.otherName || "the other racer"} left`);
        this.on.change();
        return;
      case "signaling-closed":
        if (["replaced", "session-superseded", "room-expired"].includes(ev.code)) { this.leave(); this.on.over("the race room closed"); }
        return;
    }
  }
  hello() { this.sendMeta({ name: this.name }); }
  sendMeta(obj) { if (this.game && this.other >= 0) this.game.sendReliable(this.other, new TextEncoder().encode(JSON.stringify(obj))).catch(() => {}); }
  meta(data) {
    let m; try { m = JSON.parse(new TextDecoder().decode(data)); } catch (e) { return; }
    const r = checkName(m && m.name);
    if (r.ok && r.text !== this.otherName) { this.otherName = r.text; this.on.change(); }
  }
  // The cable's way to the other page.
  send(bytes, reliable) {
    if (!this.game || this.other < 0) throw new Error("no race");
    if (reliable) this.game.sendReliable(this.other, bytes).catch(() => {});
    else this.game.sendBestEffort(this.other, bytes);
  }
  leave() {
    if (this.left) return;
    this.left = true;
    this.cable.unplug();
    try { if (this.game) this.game.close(); } catch (e) { /* gone */ }
  }
}

// -- the lobby on the page ---------------------------------------------------------

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
const stored = (key) => { try { return localStorage.getItem(key); } catch (e) { return null; } };
const store = (key, value) => { try { if (value == null) localStorage.removeItem(key); else localStorage.setItem(key, value); } catch (e) { /* not kept */ } };
const ASK_WAIT_MS = 60000;   // a question to race stands this long

// cable: web/link.js's Cable (its send goes to the race through raceSend).
// server: the lobby server.  listening(): our Game Boy waits for a link (2P).
// game(): where our Game Boy is, { menu, alone } (racing, not in link mode), or null when
// the page cannot tell.
// onNews(): something new while the panel is shut.  log(line).
// onStatus(text): the race's state in a line (or "" without a race), for the page's own bar.
export function initLobby({ cable, server = LOBBY_SERVER, listening = () => false, game = () => null, onNews = () => {}, onStatus = () => {}, log = () => {} }) {
  let net = null, entering = false, retry = null, retries = 0, race = null;
  let asking = null;                 // { to, code, at, timer }: our question to a racer
  const asked = new Map();           // seat -> { code, at }: their questions to us
  const racers = new Map();          // seat -> { name, busy }
  const buckets = new Map();         // seat -> what it may still say

  // -- names
  let given = stored("fsub:given");
  if (!given || !checkName(given).ok) { given = pickCallsign(); store("fsub:given", given); }
  const nameBox = $("lobbyName");
  nameBox.maxLength = MAX_NAME;
  nameBox.placeholder = given;
  nameBox.value = stored("fsub:name") || "";
  const myName = () => { const r = checkName(nameBox.value); return r.ok ? r.text : given; };
  const theirName = (id) => (racers.get(id) || {}).name || `Racer ${id + 1}`;
  nameBox.addEventListener("change", () => {
    const r = checkName(nameBox.value);
    if (nameBox.value.trim() && !r.ok) { note(whyText(r.why).replace("in the lobby", "as a name")); nameBox.value = stored("fsub:name") || ""; return; }
    store("fsub:name", r.ok ? r.text : null);
    hellos();
    if (race) { race.name = myName(); race.hello(); }
    show();
  });

  // -- the log
  function line(cls, ...parts) {
    const div = el("div", cls);
    for (const p of parts) div.append(p);
    const box = $("chatLog");
    const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 6;
    box.appendChild(div);
    while (box.children.length > 200) box.firstChild.remove();
    if (atBottom) box.scrollTop = box.scrollHeight;
    if (cls !== "sys") onNews();
  }
  const sys = (text) => line("sys", text);
  let noted = "", notedTimer = null;
  function note(text) { noted = text; clearTimeout(notedTimer); notedTimer = setTimeout(() => { noted = ""; hint(); }, 6000); hint(); }

  // -- the lobby connection
  const inside = () => !!net && net.selfId >= 0 && !entering;
  const others = () => (net ? net.players.filter((p) => p.id !== net.selfId && p.occupied && net.open(p.id)) : []);
  const every = (receiving) => lineEvery(others().length + 1, receiving);
  const mine = makeBucket({ every: () => every(false), at: Date.now() });
  const busyWith = () => (race && race.phase === "connected" ? race.otherName || "someone" : race ? "…" : "");
  const sendTo = (id, obj) => net && net.send(id, JSON.stringify(obj));
  const hello = (id, reply) => sendTo(id, { t: "hello", name: myName(), busy: busyWith(), reply: !!reply });
  const hellos = () => { for (const p of others()) hello(p.id, true); };

  async function enter() {
    if (net || entering) return;
    store("fsub:lobby", null);
    entering = true; clearTimeout(retry);
    show();
    const n = new HallNet({
      server, code: LOBBY_CODE, log,
      on: {
        roster: () => show(),
        link: (id, open) => {
          if (open) { hello(id, false); return; }
          if (racers.has(id)) { sys(`${theirName(id)} left`); racers.delete(id); }
          asked.delete(id);
          if (asking && asking.to === id) dropAsk();
          show();
        },
        message: (id, text) => heard(id, text),
        lost: (code, message) => {
          if (net !== n) return;
          net = null; racers.clear(); asked.clear(); dropAsk();
          sys(`The lobby connection was lost (${message}).`);
          show();
          later();
        },
      },
    });
    net = n;
    try {
      await n.connect();
      if (net !== n) { n.close(); return; }
      entering = false; retries = 0;
      sys(`You are in the lobby${n.code === LOBBY_CODE ? "" : " " + n.code} as ${myName()}.`);
    } catch (err) {
      if (net === n) net = null;
      entering = false;
      if (err.code !== "closed") {
        sys(serverDown(err.code) ? "The lobby server cannot be reached; trying again in a while." : `The lobby is not open (${err.message}).`);
        later();
      }
    }
    show();
  }
  function later() {
    clearTimeout(retry);
    if (stored("fsub:lobby") === "off") return;
    retry = setTimeout(() => { if (!net) enter(); }, Math.min(120000, 5000 * 2 ** retries++));
  }
  function leave() {
    store("fsub:lobby", "off");
    clearTimeout(retry);
    dropAsk();
    if (net) { net.close(); net = null; sys("You left the lobby."); }
    entering = false; racers.clear(); asked.clear();
    show();
  }

  // -- what the others say
  function heard(id, text) {
    if (typeof text !== "string" || text.length > 600) return;
    let m; try { m = JSON.parse(text); } catch (e) { return; }
    if (!m || typeof m !== "object") return;
    switch (m.t) {
      case "hello": {
        const r = checkName(m.name);
        const was = racers.get(id);
        const busy = typeof m.busy === "string" && (m.busy === "…" || checkName(m.busy).ok) ? m.busy : "";
        racers.set(id, { name: r.ok ? r.text : `Racer ${id + 1}`, busy });
        if (!was) sys(`${theirName(id)} is here`);
        else if (was.name !== theirName(id)) sys(`${was.name} is now ${theirName(id)}`);
        if (!m.reply) hello(id, true);
        show();
        return;
      }
      case "chat": {
        if (!buckets.has(id)) buckets.set(id, makeBucket({ every: () => every(true), at: Date.now() }));
        if (!buckets.get(id).take(Date.now())) return;
        const r = checkMessage(m.text);
        if (r.ok) line("", el("span", "name", theirName(id)), ": " + r.text);
        return;
      }
      case "ask":
        if (!isRaceCode(m.code)) return;
        if (race) { sendTo(id, { t: "no", code: m.code }); return; }
        asked.set(id, { code: m.code, at: Date.now() });
        sys(`${theirName(id)} wants to race you.`);
        show();
        return;
      case "drop":
        if (asked.has(id) && asked.get(id).code === m.code) { asked.delete(id); show(); }
        return;
      case "yes":
        if (asking && asking.to === id && asking.code === m.code) { const code = asking.code; dropAsk(); startRace(code, theirName(id), true); }
        return;
      case "no":
        if (asking && asking.to === id && asking.code === m.code) { dropAsk(); sys(`${theirName(id)} cannot race right now.`); show(); }
        return;
    }
  }

  // -- asking and answering
  function ask(id) {
    if (race || !net) return;
    if (asking) { sendTo(asking.to, { t: "drop", code: asking.code }); dropAsk(); }
    const code = newRaceCode();
    asking = { to: id, code, at: Date.now(), timer: setTimeout(() => { if (asking && asking.code === code) { sendTo(asking.to, { t: "drop", code }); dropAsk(); sys(`No answer from ${theirName(id)}.`); show(); } }, ASK_WAIT_MS) };
    sendTo(id, { t: "ask", code });
    sys(`You asked ${theirName(id)} to race.`);
    show();
  }
  function dropAsk() { if (asking) clearTimeout(asking.timer); asking = null; }
  function answer(id, yes) {
    const q = asked.get(id);
    if (!q) return;
    asked.delete(id);
    sendTo(id, { t: yes ? "yes" : "no", code: q.code });
    if (yes) {
      for (const [other, oq] of asked) sendTo(other, { t: "no", code: oq.code });
      asked.clear();
      startRace(q.code, theirName(id), false);
    }
    show();
  }

  // -- the race
  function startRace(code, withName, host) {
    if (race) race.leave();
    dropAsk();
    const r = race = new Race({
      server, code, cable, name: myName(), host, log,
      on: {
        change: () => { if (race === r) { hellos(); show(); } },
        over: (why) => { if (race === r) { race = null; sys(`The race is over: ${why}.`); hellos(); show(); } },
      },
    });
    race.otherName = withName || "";
    race.join();
    hellos();
    show();
  }
  function endRace() {
    if (!race) return;
    race.leave(); race = null;
    sys("You left the race.");
    hellos();
    show();
  }
  const raceLink = (code) => { const u = new URL(location.href); u.search = ""; u.hash = ""; u.searchParams.set("race", code); return u.toString(); };
  async function invite() {
    const code = newRaceCode();
    startRace(code, "", true);
    race.invite = raceLink(code);
    try { await navigator.clipboard.writeText(race.invite); note("Link copied: send it to a friend."); } catch (e) { note("Copy the link below and send it to a friend."); }
    show();
  }

  // -- what the panel shows
  // What the player is to do next, in a line: the panel's box, and the page's own bar.
  // (Once both Game Boys wait in link mode the page presses Start itself: link.js autoCall.)
  function raceText() {
    const me = listening();
    if (!race) return me ? "LINK needs a second player: press Race next to somebody in the lobby, or Invite a friend and send them the link." : "";
    const who = race.otherName || "your friend";
    if (race.phase === "joining") return "Opening the race…";
    if (race.phase === "alone") return race.invite ? "Waiting for your friend to open the link:" : `Waiting for ${who} to join the race…`;
    if (race.phase === "connecting") return `Connecting to ${who}…`;
    const st = cable.state, peer = cable.peer, g = game();
    if (st === "master" || st === "slave") return `Linked with ${who}: race on!`;
    if (st === "calling" || (me && peer.listening)) return `Linking with ${who}…`;
    // Whose track and rivals count: the host's (whose page makes the call).
    const rules = race.host ? " Your TRACK and RIVALS count (RIVALS NONE: just the two of you)." : ` ${who} hosts: ${who}'s track and rivals count.`;
    const them = peer.menu ? `${who} is in the menu and has to press GAS` : peer.alone ? `${who} is racing alone and has to press SELECT+START for the menu, then GAS` : `${who} has to set MODE to LINK and press GAS`;
    if (me) return `Your Game Boy waits (2P). ${them}.`;
    if (g && g.alone) return `You are racing alone: press SELECT+START for the menu, then GAS, to race ${who}.`;
    if (g && g.menu) return (g.link ? `Press GAS to race ${who}.` : `Set MODE to LINK and press GAS to race ${who}.`) + rules;
    return `Connected to ${who}: set MODE to LINK in the menu and press GAS.` + rules;
  }
  let lastRaceText = "";
  function showRace() {
    const box = $("race"), t = raceText();
    box.hidden = !t;
    box.classList.toggle("alone", !race);
    $("raceEnd").hidden = !race;
    if (t !== lastRaceText) { lastRaceText = t; $("raceText").textContent = t; onStatus(t); }
    const a = $("raceLink");
    a.hidden = !(race && race.invite && race.phase === "alone");
    if (race && race.invite) { a.href = race.invite; a.textContent = race.invite; }
  }
  function hint() {
    const box = $("chatHint");
    if (!inside()) { box.textContent = noted; return; }
    const left = MAX_CHARS - Array.from($("chatInput").value).length;
    const wait = mine.wait(Date.now());
    box.textContent = noted || (wait > 0 ? `You can send again in ${Math.ceil(wait / 1000)} s.` : left <= 15 ? `${left} characters left.` : "");
  }
  function show() {
    $("lobbyState").textContent = inside() ? `${others().length + 1} here` : entering ? "connecting…" : stored("fsub:lobby") === "off" ? "left" : "offline";
    $("lobbyEnter").hidden = !!net || entering;
    $("lobbyLeave").hidden = !net && !entering;
    $("chatInput").disabled = !inside();
    $("invite").disabled = !!race;
    // Questions to us: the newest one.
    let q = null;
    for (const [id, a] of asked) if (Date.now() - a.at > ASK_WAIT_MS) asked.delete(id); else if (!q || a.at > q.at) q = { id, ...a };
    $("ask").hidden = !q;
    if (q) { $("askText").textContent = `${theirName(q.id)} wants to race.`; $("ask").dataset.id = q.id; }
    // The racers.
    const list = $("roster");
    list.textContent = "";
    const meRow = el("li", "me");
    meRow.append(el("span", "name", myName() + " (you)"));
    if (race) meRow.append(el("span", "busy", race.phase === "connected" ? `racing ${race.otherName || ""}` : "in a race room"));
    list.append(meRow);
    for (const p of others()) {
      const r = racers.get(p.id);
      if (!r) continue;
      const li = el("li");
      li.append(el("span", "name", r.name));
      if (r.busy) li.append(el("span", "busy", r.busy === "…" ? "in a race room" : `racing ${r.busy}`));
      const b = el("button", "", asking && asking.to === p.id ? "Asked…" : "Race");
      b.disabled = !!race || !!r.busy || (asking && asking.to === p.id);
      b.title = `Ask ${r.name} to race: you link your Game Boys`;
      b.addEventListener("click", () => ask(p.id));
      li.append(b);
      list.append(li);
    }
    showRace();
    hint();
  }

  // -- the controls
  $("chatForm").addEventListener("submit", (ev) => {
    ev.preventDefault();
    if (!inside()) return;
    const input = $("chatInput");
    const r = checkMessage(input.value);
    if (!r.ok) { if (r.why !== "empty") note(whyText(r.why)); return; }
    if (!mine.take(Date.now())) { hint(); return; }
    for (const p of others()) sendTo(p.id, { t: "chat", text: r.text });
    line("mine", el("span", "name me", myName()), ": " + r.text);
    input.value = "";
    hint();
  });
  $("chatInput").addEventListener("input", () => { noted = ""; hint(); });
  $("askYes").addEventListener("click", () => answer(Number($("ask").dataset.id), true));
  $("askNo").addEventListener("click", () => answer(Number($("ask").dataset.id), false));
  $("raceEnd").addEventListener("click", endRace);
  $("invite").addEventListener("click", invite);
  $("lobbyLeave").addEventListener("click", leave);
  $("lobbyEnter").addEventListener("click", () => { retries = 0; enter(); });
  addEventListener("pagehide", () => { if (race) race.leave(); if (net) net.close(); });
  addEventListener("pageshow", (ev) => { if (ev.persisted) location.reload(); });   // (back from the page cache with both closed)
  setInterval(() => { showRace(); hint(); }, 500);
  cable.on = (what) => { if (what === "state" && (cable.state === "master" || cable.state === "slave")) hellos(); showRace(); };

  const q = new URLSearchParams(location.search);
  if (isRaceCode(q.get("race"))) startRace(q.get("race"), "", false);
  show();
  return {
    // The panel was opened: enter the lobby (unless the player left it on purpose:
    // "Enter the lobby" brings them back).
    open: () => { if (!net && !entering && stored("fsub:lobby") !== "off") { retries = 0; enter(); } },
    raceSend: (bytes, reliable) => { if (!race) throw new Error("no race"); race.send(bytes, reliable); },
    get race() { return race; }, get net() { return net; },
  };
}

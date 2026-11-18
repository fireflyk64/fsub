/**
 * lobbylink browser client: lobby membership over a WebSocket signaling
 * server plus peer-to-peer WebRTC DataChannels between all players.
 *
 * Zero runtime dependencies; everything here compiles with plain `tsc`
 * to a single ES module that is both the npm entry point and the
 * browser bundle (`web/p2p-client.js`). The whole implementation lives
 * in this one file on purpose: tsc cannot bundle multi-file ES modules,
 * and a single file is what game developers can copy straight into
 * their project.
 *
 * Wire compatibility notes (the Rust client must match):
 *  - Signaling protocol: see the repo implementation guide §4.
 *  - Per peer pair, two pre-negotiated SCTP DataChannels:
 *      "reliable"    negotiated id=1, ordered, fully reliable
 *      "best-effort" negotiated id=2, unordered, maxRetransmits=0
 *    Both sides create both channels; the lower player ID of the pair
 *    creates the SDP offer, the higher answers.
 *  - Reliable payloads are chunked into binary frames (big-endian):
 *      offset 0  u8  magic      0x4C ('L')
 *      offset 1  u8  version    0x01
 *      offset 2  u32 msgId      per-sender counter, wraps mod 2^32
 *      offset 6  u32 seq        0-based chunk index
 *      offset 10 u32 total      chunk count for this message (>= 1)
 *      offset 14 u32 payloadLen payload bytes in this frame
 *      offset 18 ... payload
 *    Chunk payload is 16 KiB (last chunk may be shorter); a frame
 *    payload larger than 64 KiB is invalid. Reassembly is keyed by
 *    (sender, msgId) and incomplete messages are dropped after 30 s.
 *  - Best-effort payloads are sent raw (no framing), at most 16000
 *    bytes each; keeping them under ~1200 bytes avoids SCTP
 *    fragmentation, where losing any fragment loses the message.
 */
// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------
/**
 * Error carrying a stable machine-readable `code`. Server-reported
 * codes (e.g. "room-full", "slot-not-claimable") pass through
 * unchanged; client-side failures use codes like "connect-timeout",
 * "connection-lost", "invalid-target", "message-too-large",
 * "channel-timeout", "send-failed", "closed".
 */
export class LobbyError extends Error {
    constructor(code, message) {
        super(message);
        this.name = "LobbyError";
        this.code = code;
    }
}
// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------
const FRAME_MAGIC = 0x4c;
const FRAME_VERSION = 0x01;
const FRAME_HEADER_LEN = 18;
/** Payload bytes per reliable chunk. */
const CHUNK_PAYLOAD = 16 * 1024;
/** A received frame may not carry more payload than this. */
const MAX_FRAME_PAYLOAD = 64 * 1024;
/** Send- and receive-side cap on one reliable message. */
const MAX_RELIABLE_MESSAGE = 16 * 1024 * 1024;
const MAX_REASSEMBLY_CHUNKS = 4096;
const REASSEMBLY_TIMEOUT_MS = 30000;
const MAX_BEST_EFFORT = 16000;
/** Pause chunk sends above this bufferedAmount... */
const SEND_HIGH_WATER = 1 << 20;
/** ...and resume once it drains below this. */
const SEND_LOW_WATER = 256 * 1024;
const CONNECT_TIMEOUT_MS = 20000;
/** How long sendReliable waits for a usable channel to the target. */
const CHANNEL_TIMEOUT_MS = 30000;
const RELIABLE_CHANNEL_ID = 1;
const BEST_EFFORT_CHANNEL_ID = 2;
/** Automatic ICE-failure rebuilds per peer before giving up. */
const MAX_PEER_REBUILDS = 3;
/** Buffered events before the first onEvent listener registers. */
const MAX_PENDING_EVENTS = 256;
const CODE_RE = /^[A-Za-z0-9_-]{4,64}$/;
/** Server error codes after which the WebSocket will not come back. */
const FATAL_CODES = new Set([
    "replaced",
    "session-superseded",
    "room-expired",
    "slow-consumer",
]);
/** Fatal codes that also mean our peers are gone / we left the room. */
const GAME_OVER_CODES = new Set([
    "replaced",
    "session-superseded",
    "room-expired",
]);
// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
/**
 * Normalize a server URL to the wss/ws signaling endpoint:
 * http(s) becomes ws(s) and "/ws" is appended unless already present,
 * so subpath deployments like https://host/lobbylink work unchanged.
 */
function signalingUrl(server) {
    let u;
    try {
        u = new URL(server);
    }
    catch {
        throw new LobbyError("invalid-server-url", `invalid server URL: ${server}`);
    }
    switch (u.protocol) {
        case "http:":
            u.protocol = "ws:";
            break;
        case "https:":
            u.protocol = "wss:";
            break;
        case "ws:":
        case "wss:":
            break;
        default:
            throw new LobbyError("invalid-server-url", `unsupported scheme ${u.protocol} in server URL`);
    }
    let path = u.pathname.replace(/\/+$/, "");
    if (!path.endsWith("/ws"))
        path += "/ws";
    u.pathname = path;
    u.search = "";
    u.hash = "";
    return u.toString();
}
function pickStorage(kind) {
    try {
        return kind === "session" ? globalThis.sessionStorage : globalThis.localStorage;
    }
    catch {
        return undefined;
    }
}
function loadToken(key, kind) {
    if (!key)
        return undefined;
    try {
        return pickStorage(kind)?.getItem(key) ?? undefined;
    }
    catch {
        return undefined;
    }
}
function saveToken(key, kind, token) {
    if (!key)
        return;
    try {
        pickStorage(kind)?.setItem(key, token);
    }
    catch {
        // Storage unavailable (private mode, quota): resume just won't work.
    }
}
function clearToken(key, kind) {
    if (!key)
        return;
    try {
        pickStorage(kind)?.removeItem(key);
    }
    catch {
        // ignore
    }
}
function toBytes(data) {
    return data instanceof Uint8Array ? data : new Uint8Array(data);
}
/**
 * RTCDataChannel.send is typed for non-shared buffers only; our
 * Uint8Arrays never wrap a SharedArrayBuffer, so the cast is sound.
 */
function dcSend(dc, bytes) {
    dc.send(bytes);
}
function warn(...args) {
    console.warn("[lobbylink]", ...args);
}
// ---------------------------------------------------------------------------
// Reliable-channel framing
// ---------------------------------------------------------------------------
function makeFrame(msgId, seq, total, payload) {
    const frame = new Uint8Array(FRAME_HEADER_LEN + payload.byteLength);
    const dv = new DataView(frame.buffer);
    dv.setUint8(0, FRAME_MAGIC);
    dv.setUint8(1, FRAME_VERSION);
    dv.setUint32(2, msgId >>> 0);
    dv.setUint32(6, seq >>> 0);
    dv.setUint32(10, total >>> 0);
    dv.setUint32(14, payload.byteLength >>> 0);
    frame.set(payload, FRAME_HEADER_LEN);
    return frame;
}
function parseFrame(buf) {
    if (buf.byteLength < FRAME_HEADER_LEN)
        return "frame shorter than header";
    const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    if (dv.getUint8(0) !== FRAME_MAGIC)
        return "bad frame magic";
    if (dv.getUint8(1) !== FRAME_VERSION)
        return "unsupported frame version";
    const msgId = dv.getUint32(2);
    const seq = dv.getUint32(6);
    const total = dv.getUint32(10);
    const payloadLen = dv.getUint32(14);
    if (total < 1 || total > MAX_REASSEMBLY_CHUNKS)
        return "bad frame total";
    if (seq >= total)
        return "frame seq out of range";
    if (payloadLen > MAX_FRAME_PAYLOAD)
        return "frame payload too large";
    if (payloadLen !== buf.byteLength - FRAME_HEADER_LEN) {
        return "frame payload length mismatch";
    }
    return {
        msgId,
        seq,
        total,
        payload: buf.subarray(FRAME_HEADER_LEN),
    };
}
/** Per-sender reassembly of chunked reliable messages. */
class Reassembler {
    constructor() {
        this.inflight = new Map();
    }
    /** Feed one frame; returns the full message when it completes. */
    push(frame) {
        const now = Date.now();
        this.prune(now);
        let entry = this.inflight.get(frame.msgId);
        if (entry && entry.total !== frame.total) {
            // msgId reuse with different geometry: treat as a new message.
            this.inflight.delete(frame.msgId);
            entry = undefined;
        }
        if (!entry) {
            entry = {
                total: frame.total,
                chunks: new Array(frame.total),
                received: 0,
                bytes: 0,
                startedAt: now,
            };
            this.inflight.set(frame.msgId, entry);
        }
        if (entry.chunks[frame.seq] === undefined) {
            // Copy: the payload view aliases the transient receive buffer.
            entry.chunks[frame.seq] = frame.payload.slice();
            entry.received++;
            entry.bytes += frame.payload.byteLength;
            if (entry.bytes > MAX_RELIABLE_MESSAGE) {
                warn("dropping oversized reliable message", entry.bytes, "bytes");
                this.inflight.delete(frame.msgId);
                return undefined;
            }
        }
        if (entry.received < entry.total)
            return undefined;
        this.inflight.delete(frame.msgId);
        const out = new Uint8Array(entry.bytes);
        let off = 0;
        for (const chunk of entry.chunks) {
            if (!chunk)
                return undefined; // unreachable; satisfies the checker
            out.set(chunk, off);
            off += chunk.byteLength;
        }
        return out;
    }
    prune(now) {
        for (const [msgId, entry] of this.inflight) {
            if (now - entry.startedAt > REASSEMBLY_TIMEOUT_MS) {
                warn(`dropping incomplete reliable message ${msgId} (timeout)`);
                this.inflight.delete(msgId);
            }
        }
    }
}
class PeerLink {
    constructor(playerId, initiator, config) {
        this.reassembler = new Reassembler();
        this.closed = false;
        this.nextMsgId = 0;
        /** ICE candidates that arrived before the remote description. */
        this.pendingCandidates = [];
        this.playerId = playerId;
        this.initiator = initiator;
        this.pc = new RTCPeerConnection(config);
        this.reliable = this.pc.createDataChannel("reliable", {
            negotiated: true,
            id: RELIABLE_CHANNEL_ID,
            ordered: true,
        });
        this.bestEffort = this.pc.createDataChannel("best-effort", {
            negotiated: true,
            id: BEST_EFFORT_CHANNEL_ID,
            ordered: false,
            maxRetransmits: 0,
        });
        this.reliable.binaryType = "arraybuffer";
        this.bestEffort.binaryType = "arraybuffer";
    }
    /** Resolves when the reliable channel is open; rejects on teardown. */
    waitReliableOpen() {
        if (this.reliable.readyState === "open")
            return Promise.resolve();
        if (this.closed || this.reliable.readyState !== "connecting") {
            return Promise.reject(new LobbyError("peer-closed", `channel to player ${this.playerId} is closed`));
        }
        if (!this.openWait) {
            this.openWait = new Promise((resolve, reject) => {
                let timer;
                const settle = (fn) => {
                    clearTimeout(timer);
                    this.openSettle = undefined;
                    fn();
                };
                this.openSettle = {
                    resolve: () => settle(resolve),
                    reject: (e) => settle(() => reject(e)),
                };
                this.reliable.addEventListener("open", () => this.openSettle?.resolve());
                this.reliable.addEventListener("close", () => this.openSettle?.reject(new LobbyError("peer-closed", `channel to player ${this.playerId} closed`)));
                timer = setTimeout(() => this.openSettle?.reject(new LobbyError("channel-timeout", `timed out opening channel to player ${this.playerId}`)), CHANNEL_TIMEOUT_MS);
            });
            this.openWait.catch(() => { }); // avoid unhandled-rejection noise
        }
        return this.openWait;
    }
    /** Waits until bufferedAmount drains below the low-water mark. */
    awaitDrain() {
        const dc = this.reliable;
        if (dc.bufferedAmount <= SEND_HIGH_WATER)
            return Promise.resolve();
        dc.bufferedAmountLowThreshold = SEND_LOW_WATER;
        return new Promise((resolve, reject) => {
            let interval;
            const cleanup = () => {
                clearInterval(interval);
                dc.removeEventListener("bufferedamountlow", onLow);
                dc.removeEventListener("close", onClose);
            };
            const onLow = () => {
                cleanup();
                resolve();
            };
            const onClose = () => {
                cleanup();
                reject(new LobbyError("peer-closed", `channel to player ${this.playerId} closed`));
            };
            dc.addEventListener("bufferedamountlow", onLow);
            dc.addEventListener("close", onClose);
            // Fallback poll in case the events never fire (teardown races).
            interval = setInterval(() => {
                if (this.closed)
                    onClose();
                else if (dc.bufferedAmount <= SEND_LOW_WATER)
                    onLow();
            }, 200);
        });
    }
    close() {
        if (this.closed)
            return;
        this.closed = true;
        this.openSettle?.reject(new LobbyError("peer-closed", `connection to player ${this.playerId} closed`));
        this.pendingCandidates = null;
        try {
            this.reliable.close();
        }
        catch {
            /* ignore */
        }
        try {
            this.bestEffort.close();
        }
        catch {
            /* ignore */
        }
        try {
            this.pc.close();
        }
        catch {
            /* ignore */
        }
    }
}
// ---------------------------------------------------------------------------
// P2PGame
// ---------------------------------------------------------------------------
export class P2PGame {
    /** Join (optionally creating) or claim a slot in a room. */
    static connect(opts) {
        return new Promise((resolve, reject) => {
            if (!CODE_RE.test(opts.code)) {
                reject(new LobbyError("invalid-code", "room code must be 4-64 chars of [A-Za-z0-9_-]"));
                return;
            }
            let url;
            try {
                url = signalingUrl(opts.server);
            }
            catch (err) {
                reject(err);
                return;
            }
            let ws;
            try {
                ws = new WebSocket(url);
            }
            catch (err) {
                reject(new LobbyError("connection-failed", `cannot open ${url}: ${String(err)}`));
                return;
            }
            ws.binaryType = "arraybuffer";
            let settled = false;
            const fail = (err) => {
                if (settled)
                    return;
                settled = true;
                clearTimeout(timer);
                try {
                    ws.close();
                }
                catch {
                    /* ignore */
                }
                reject(err);
            };
            const timer = setTimeout(() => fail(new LobbyError("connect-timeout", `timed out connecting to ${url}`)), CONNECT_TIMEOUT_MS);
            ws.onopen = () => {
                const msg = opts.claimPlayerId != null
                    ? { type: "claim-slot", code: opts.code, playerId: opts.claimPlayerId }
                    : { type: "join", code: opts.code };
                if (opts.appId)
                    msg.appId = opts.appId;
                if (opts.claimPlayerId == null) {
                    const token = opts.resumeToken ?? loadToken(opts.storageKey, opts.storage);
                    if (token)
                        msg.resumeToken = token;
                    if (opts.create)
                        msg.create = opts.create;
                }
                ws.send(JSON.stringify(msg));
            };
            ws.onerror = () => fail(new LobbyError("connection-failed", `WebSocket error on ${url}`));
            ws.onclose = (ev) => fail(new LobbyError("connection-closed", `connection closed before join completed (${ev.code})`));
            ws.onmessage = (ev) => {
                if (typeof ev.data !== "string")
                    return;
                let msg;
                try {
                    msg = JSON.parse(ev.data);
                }
                catch {
                    fail(new LobbyError("invalid-message", "server sent malformed JSON"));
                    return;
                }
                if (msg.type === "joined") {
                    settled = true;
                    clearTimeout(timer);
                    resolve(new P2PGame(ws, msg, opts));
                }
                else if (msg.type === "error") {
                    fail(new LobbyError(msg.code, msg.message));
                }
                // Anything else before "joined" is unexpected; ignore.
            };
        });
    }
    constructor(ws, joined, opts) {
        this.closedFlag = false;
        this.fatalSeen = false;
        this.peers = new Map();
        this.linkWaiters = new Map();
        this.sendChains = new Map();
        this.rebuildCounts = new Map();
        this.listeners = new Set();
        this.pendingEvents = [];
        this.ws = ws;
        this.code = joined.code;
        this.selfId = joined.selfId;
        this.maxPlayers = joined.maxPlayers;
        this.resumeToken = joined.resumeToken;
        this.startedFlag = joined.started;
        this.roster = joined.players.map((p) => ({ ...p }));
        this.storageKey = opts.storageKey;
        this.storageKind = opts.storage;
        const iceServers = [...(joined.iceServers ?? []), ...(opts.iceServers ?? [])];
        this.iceServers = iceServers;
        this.rtcConfig = {
            iceServers,
            ...(opts.forceRelay ? { iceTransportPolicy: "relay" } : {}),
        };
        saveToken(this.storageKey, this.storageKind, joined.resumeToken);
        ws.onmessage = (ev) => {
            if (typeof ev.data !== "string")
                return;
            let msg;
            try {
                msg = JSON.parse(ev.data);
            }
            catch {
                warn("malformed server message");
                return;
            }
            this.handleServerMessage(msg);
        };
        ws.onerror = () => {
            /* onclose carries the state change */
        };
        ws.onclose = () => {
            if (this.closedFlag || this.fatalSeen)
                return;
            this.fatalSeen = true;
            this.emit({
                type: "signaling-closed",
                code: "connection-lost",
                message: "signaling connection lost; existing peer channels stay up",
            });
        };
        // Lower ID initiates: offer to every connected peer with a higher ID.
        // Peers with lower IDs will offer to us when they see player-joined
        // or player-rejoined.
        for (const p of this.roster) {
            if (p.id !== this.selfId && p.occupied && p.connected && this.selfId < p.id) {
                void this.initiatePeer(p.id);
            }
        }
    }
    /** True once the room has reached its start condition. */
    get started() {
        return this.startedFlag;
    }
    /** Snapshot of all room slots. */
    get players() {
        return this.roster.map((p) => ({
            id: p.id,
            occupied: p.occupied,
            connected: p.connected,
        }));
    }
    /**
     * Subscribe to events. Events fired before the first listener
     * registers are buffered and replayed. Returns an unsubscribe
     * function.
     */
    onEvent(cb) {
        this.listeners.add(cb);
        if (this.pendingEvents.length > 0) {
            const backlog = this.pendingEvents;
            this.pendingEvents = [];
            queueMicrotask(() => {
                for (const ev of backlog)
                    this.emit(ev);
            });
        }
        return () => this.listeners.delete(cb);
    }
    /**
     * Send one datagram on the unordered, no-retransmit channel. Silently
     * dropped if the channel is not open or its buffer is full (that is
     * the best-effort contract). Throws only on caller errors: bad
     * target or payload over 16000 bytes.
     */
    sendBestEffort(to, data) {
        const bytes = toBytes(data);
        this.checkTarget(to);
        if (bytes.byteLength > MAX_BEST_EFFORT) {
            throw new LobbyError("message-too-large", `best-effort payload ${bytes.byteLength} exceeds ${MAX_BEST_EFFORT} bytes`);
        }
        this.bestEffortTo(to, bytes);
    }
    /** sendBestEffort to every other occupied slot. */
    broadcastBestEffort(data) {
        const bytes = toBytes(data);
        if (bytes.byteLength > MAX_BEST_EFFORT) {
            throw new LobbyError("message-too-large", `best-effort payload ${bytes.byteLength} exceeds ${MAX_BEST_EFFORT} bytes`);
        }
        for (const p of this.roster) {
            if (p.id !== this.selfId && p.occupied)
                this.bestEffortTo(p.id, bytes);
        }
    }
    /**
     * Send a reliable, ordered message (chunked over the reliable
     * channel, up to 16 MiB). Resolves once every chunk has been handed
     * to the transport; rejects if the peer link cannot be established
     * or dies mid-send. Sends to the same peer are serialized.
     */
    sendReliable(to, data) {
        const bytes = toBytes(data);
        try {
            this.checkTarget(to);
            if (!this.roster[to]?.occupied) {
                throw new LobbyError("target-unavailable", `no player in slot ${to}`);
            }
            if (bytes.byteLength > MAX_RELIABLE_MESSAGE) {
                throw new LobbyError("message-too-large", `reliable payload ${bytes.byteLength} exceeds ${MAX_RELIABLE_MESSAGE} bytes`);
            }
        }
        catch (err) {
            return Promise.reject(err);
        }
        const prev = this.sendChains.get(to) ?? Promise.resolve();
        const send = prev.then(() => this.sendReliableNow(to, bytes));
        this.sendChains.set(to, send.catch(() => { }));
        return send;
    }
    /**
     * Leave the room and release all resources. Sends an explicit leave
     * (freeing our slot) and clears any stored resume token.
     */
    close() {
        if (this.closedFlag)
            return;
        this.closedFlag = true;
        try {
            if (this.ws.readyState === WebSocket.OPEN) {
                this.ws.send(JSON.stringify({ type: "leave" }));
            }
        }
        catch {
            /* ignore */
        }
        try {
            this.ws.close(1000, "client closed");
        }
        catch {
            /* ignore */
        }
        this.teardownPeers();
        clearToken(this.storageKey, this.storageKind);
        this.listeners.clear();
        this.pendingEvents = [];
    }
    // -- events ---------------------------------------------------------------
    emit(ev) {
        if (this.closedFlag)
            return;
        if (this.listeners.size === 0) {
            if (this.pendingEvents.length < MAX_PENDING_EVENTS)
                this.pendingEvents.push(ev);
            return;
        }
        for (const cb of [...this.listeners]) {
            try {
                cb(ev);
            }
            catch (err) {
                console.error("[lobbylink] onEvent listener threw:", err);
            }
        }
    }
    // -- lobby message handling -------------------------------------------------
    handleServerMessage(msg) {
        switch (msg.type) {
            case "player-joined": {
                this.roster = msg.players.map((p) => ({ ...p }));
                this.emit({ type: "player-joined", playerId: msg.playerId });
                this.resetPeer(msg.playerId);
                break;
            }
            case "player-left": {
                const reason = msg.reason === "explicit-leave" ? "explicit-leave" : "disconnected";
                const slot = this.roster[msg.playerId];
                if (slot) {
                    if (reason === "explicit-leave")
                        slot.occupied = false;
                    slot.connected = false;
                }
                if (reason === "explicit-leave")
                    this.closePeer(msg.playerId);
                // On "disconnected" the peer only lost signaling; an
                // established DataChannel may well still be alive, so keep it.
                this.emit({ type: "player-left", playerId: msg.playerId, reason });
                break;
            }
            case "player-rejoined": {
                const slot = this.roster[msg.playerId];
                if (slot) {
                    slot.occupied = true;
                    slot.connected = true;
                }
                this.emit({
                    type: "player-rejoined",
                    playerId: msg.playerId,
                    wasReplacement: msg.wasReplacement,
                });
                this.resetPeer(msg.playerId);
                break;
            }
            case "player-replaced": {
                const slot = this.roster[msg.playerId];
                if (slot) {
                    slot.occupied = true;
                    slot.connected = true;
                }
                this.emit({ type: "player-replaced", playerId: msg.playerId });
                this.resetPeer(msg.playerId);
                break;
            }
            case "room-started": {
                this.startedFlag = true;
                this.emit({ type: "started" });
                break;
            }
            case "signal": {
                void this.handleSignal(msg.from, msg.payload);
                break;
            }
            case "error": {
                if (FATAL_CODES.has(msg.code)) {
                    this.fatalSeen = true;
                    if (GAME_OVER_CODES.has(msg.code)) {
                        this.teardownPeers();
                        // "session-superseded" means our own token resumed from
                        // another tab, which just stored its new token under the
                        // same storageKey — don't clobber it.
                        if (msg.code !== "session-superseded") {
                            clearToken(this.storageKey, this.storageKind);
                        }
                    }
                    this.emit({ type: "signaling-closed", code: msg.code, message: msg.message });
                }
                else {
                    this.emit({ type: "lobby-error", code: msg.code, message: msg.message });
                }
                break;
            }
            case "joined":
                // Only expected once, handled in connect().
                break;
            default:
                // Unknown message types are ignored for forward compatibility.
                break;
        }
    }
    /** A peer got a new session: drop the old link, re-offer if initiator. */
    resetPeer(playerId) {
        if (playerId === this.selfId)
            return;
        this.closePeer(playerId);
        this.rebuildCounts.delete(playerId);
        if (this.selfId < playerId)
            void this.initiatePeer(playerId);
    }
    // -- WebRTC signaling -------------------------------------------------------
    sendSignal(to, payload) {
        if (this.ws.readyState !== WebSocket.OPEN)
            return;
        try {
            this.ws.send(JSON.stringify({ type: "signal", to, payload }));
        }
        catch {
            /* socket died; onclose will report */
        }
    }
    createLink(playerId, initiator) {
        this.closePeer(playerId);
        const link = new PeerLink(playerId, initiator, this.rtcConfig);
        this.peers.set(playerId, link);
        link.pc.onicecandidate = (ev) => {
            if (link.closed || !ev.candidate)
                return;
            this.sendSignal(playerId, { kind: "ice", candidate: ev.candidate.toJSON() });
        };
        link.pc.onconnectionstatechange = () => {
            if (link.closed)
                return;
            const state = link.pc.connectionState;
            this.emit({ type: "peer-state", playerId, state });
            if (state === "connected") {
                this.rebuildCounts.delete(playerId);
                void this.reportCandidatePair(link);
            }
            else if (state === "failed") {
                this.handlePeerFailure(link);
            }
        };
        link.reliable.onmessage = (ev) => this.onReliableData(link, ev.data);
        link.bestEffort.onmessage = (ev) => {
            const data = this.channelBytes(ev.data);
            if (data)
                this.emit({ type: "message", from: playerId, kind: "best-effort", data });
        };
        const waiters = this.linkWaiters.get(playerId);
        if (waiters) {
            this.linkWaiters.delete(playerId);
            for (const w of waiters) {
                clearTimeout(w.timer);
                w.resolve(link);
            }
        }
        return link;
    }
    async initiatePeer(playerId) {
        if (this.closedFlag)
            return;
        const link = this.createLink(playerId, true);
        try {
            const offer = await link.pc.createOffer();
            if (link.closed)
                return;
            await link.pc.setLocalDescription(offer);
            if (link.closed)
                return;
            this.sendSignal(playerId, { kind: "offer", sdp: link.pc.localDescription.sdp });
        }
        catch (err) {
            warn(`offer to player ${playerId} failed:`, err);
        }
    }
    async handleSignal(from, payload) {
        if (this.closedFlag || from === this.selfId)
            return;
        try {
            switch (payload.kind) {
                case "offer": {
                    if (this.selfId < from) {
                        warn(`ignoring offer from higher-ID player ${from} (protocol says we offer)`);
                        return;
                    }
                    // Every incoming offer starts a fresh session (initial
                    // connect or the initiator rebuilding after a failure).
                    const link = this.createLink(from, false);
                    await link.pc.setRemoteDescription({ type: "offer", sdp: payload.sdp });
                    if (link.closed)
                        return;
                    this.flushCandidates(link);
                    const answer = await link.pc.createAnswer();
                    if (link.closed)
                        return;
                    await link.pc.setLocalDescription(answer);
                    if (link.closed)
                        return;
                    this.sendSignal(from, { kind: "answer", sdp: link.pc.localDescription.sdp });
                    break;
                }
                case "answer": {
                    const link = this.peers.get(from);
                    if (!link || link.closed || link.pc.signalingState !== "have-local-offer") {
                        warn(`ignoring stale answer from player ${from}`);
                        return;
                    }
                    await link.pc.setRemoteDescription({ type: "answer", sdp: payload.sdp });
                    this.flushCandidates(link);
                    break;
                }
                case "ice": {
                    const link = this.peers.get(from);
                    if (!link || link.closed)
                        return;
                    if (link.pc.remoteDescription === null) {
                        link.pendingCandidates?.push(payload.candidate);
                    }
                    else {
                        await this.addCandidate(link, payload.candidate);
                    }
                    break;
                }
            }
        }
        catch (err) {
            warn(`signal (${payload.kind}) from player ${from} failed:`, err);
        }
    }
    flushCandidates(link) {
        const queued = link.pendingCandidates;
        link.pendingCandidates = null;
        if (!queued)
            return;
        for (const cand of queued)
            void this.addCandidate(link, cand);
    }
    async addCandidate(link, cand) {
        try {
            // null/undefined is the cross-implementation end-of-candidates marker.
            await link.pc.addIceCandidate(cand ?? undefined);
        }
        catch (err) {
            if (!link.closed)
                warn(`addIceCandidate for player ${link.playerId} failed:`, err);
        }
    }
    handlePeerFailure(link) {
        if (!link.initiator || this.closedFlag)
            return;
        const playerId = link.playerId;
        const count = (this.rebuildCounts.get(playerId) ?? 0) + 1;
        this.rebuildCounts.set(playerId, count);
        if (count > MAX_PEER_REBUILDS) {
            warn(`giving up on player ${playerId} after ${MAX_PEER_REBUILDS} rebuilds`);
            return;
        }
        setTimeout(() => {
            const slot = this.roster[playerId];
            if (this.closedFlag ||
                this.peers.get(playerId) !== link ||
                link.pc.connectionState !== "failed" ||
                !slot?.occupied ||
                !slot.connected) {
                return;
            }
            void this.initiatePeer(playerId);
        }, 1000 * count);
    }
    async reportCandidatePair(link) {
        try {
            const stats = await link.pc.getStats();
            let pairId;
            stats.forEach((s) => {
                if (s.type === "transport" && typeof s.selectedCandidatePairId === "string") {
                    pairId = s.selectedCandidatePairId;
                }
            });
            if (!pairId) {
                stats.forEach((s) => {
                    if (s.type === "candidate-pair" &&
                        (s.selected === true || (s.nominated === true && s.state === "succeeded"))) {
                        pairId = s.id;
                    }
                });
            }
            if (!pairId || link.closed)
                return;
            const pair = stats.get(pairId);
            if (!pair)
                return;
            const local = stats.get(pair.localCandidateId);
            const remote = stats.get(pair.remoteCandidateId);
            this.emit({
                type: "candidate-pair",
                playerId: link.playerId,
                local: String(local?.candidateType ?? "unknown"),
                remote: String(remote?.candidateType ?? "unknown"),
            });
        }
        catch {
            // Stats are best-effort debug info only.
        }
    }
    // -- data path ----------------------------------------------------------------
    channelBytes(data) {
        if (data instanceof ArrayBuffer)
            return new Uint8Array(data);
        if (typeof data === "string")
            return new TextEncoder().encode(data);
        warn("dropping DataChannel message of unexpected type");
        return undefined;
    }
    onReliableData(link, data) {
        const bytes = this.channelBytes(data);
        if (!bytes)
            return;
        const frame = parseFrame(bytes);
        if (typeof frame === "string") {
            warn(`dropping reliable frame from player ${link.playerId}: ${frame}`);
            return;
        }
        const message = link.reassembler.push(frame);
        if (message) {
            this.emit({ type: "message", from: link.playerId, kind: "reliable", data: message });
        }
    }
    bestEffortTo(to, bytes) {
        const link = this.peers.get(to);
        const dc = link?.bestEffort;
        if (!dc || dc.readyState !== "open" || dc.bufferedAmount > SEND_HIGH_WATER) {
            return; // best-effort: drop
        }
        try {
            dcSend(dc, bytes);
        }
        catch {
            /* racing close: drop */
        }
    }
    async sendReliableNow(to, bytes) {
        const link = await this.awaitLink(to);
        await link.waitReliableOpen();
        const msgId = link.nextMsgId >>> 0;
        link.nextMsgId = (link.nextMsgId + 1) >>> 0;
        const total = Math.max(1, Math.ceil(bytes.byteLength / CHUNK_PAYLOAD));
        for (let seq = 0; seq < total; seq++) {
            if (link.closed) {
                throw new LobbyError("send-failed", `connection to player ${to} closed mid-send`);
            }
            if (link.reliable.bufferedAmount > SEND_HIGH_WATER) {
                await link.awaitDrain();
            }
            const start = seq * CHUNK_PAYLOAD;
            const payload = bytes.subarray(start, Math.min(start + CHUNK_PAYLOAD, bytes.byteLength));
            try {
                dcSend(link.reliable, makeFrame(msgId, seq, total, payload));
            }
            catch (err) {
                throw new LobbyError("send-failed", `send to player ${to} failed: ${String(err)}`);
            }
        }
    }
    /** Resolve the current link to a peer, waiting for one if necessary. */
    awaitLink(playerId) {
        const link = this.peers.get(playerId);
        if (link && !link.closed)
            return Promise.resolve(link);
        if (this.closedFlag) {
            return Promise.reject(new LobbyError("closed", "game is closed"));
        }
        return new Promise((resolve, reject) => {
            const waiter = {
                resolve,
                reject,
                timer: setTimeout(() => {
                    const list = this.linkWaiters.get(playerId);
                    if (list) {
                        const i = list.indexOf(waiter);
                        if (i >= 0)
                            list.splice(i, 1);
                    }
                    reject(new LobbyError("channel-timeout", `no WebRTC session with player ${playerId} within ${CHANNEL_TIMEOUT_MS}ms`));
                }, CHANNEL_TIMEOUT_MS),
            };
            const list = this.linkWaiters.get(playerId) ?? [];
            list.push(waiter);
            this.linkWaiters.set(playerId, list);
        });
    }
    checkTarget(to) {
        if (!Number.isInteger(to) || to < 0 || to >= this.maxPlayers) {
            throw new LobbyError("invalid-target", `player id ${to} out of range 0..${this.maxPlayers - 1}`);
        }
        if (to === this.selfId) {
            throw new LobbyError("invalid-target", "cannot send to yourself");
        }
    }
    // -- teardown -------------------------------------------------------------------
    closePeer(playerId) {
        const link = this.peers.get(playerId);
        if (!link)
            return;
        this.peers.delete(playerId);
        link.close();
    }
    teardownPeers() {
        for (const id of [...this.peers.keys()])
            this.closePeer(id);
        for (const [, waiters] of this.linkWaiters) {
            for (const w of waiters) {
                clearTimeout(w.timer);
                w.reject(new LobbyError("closed", "game is closed"));
            }
        }
        this.linkWaiters.clear();
    }
}

// The broker worker (spec 508): the only thread that ever touches a real
// socket, HTTP client, child process or timer for a blocking call. It owns
// the async world, so the main thread never needs to run its own event loop
// tick while a request is outstanding -- this is the only place that safely
// could anyway.
import { parentPort, workerData } from "node:worker_threads";
import net from "node:net";
import http from "node:http";
import https from "node:https";
import { spawn as nodeSpawn } from "node:child_process";
import * as P from "./protocol.mjs";
import { text } from "../lang.mjs";
// The real Node `Buffer`, not the ambient global: `globals.mjs` replaces
// `globalThis.Buffer` with Lumen's own `LumenBuffer` (spec 056), and this
// worker's own realm gets that replacement too whenever the program was
// started as `node --import .../globals.mjs prog.ts` (Node workers inherit
// `process.execArgv`, which carries `--import`, unless told not to).
// `LumenBuffer` doesn't support the 3-argument `Buffer.from(arrayBuffer,
// byteOffset, length)` form `protocol.mjs`'s decoders rely on -- see its own
// comment for how that was found. `protocol.mjs` binds the real one for
// itself; this module's own `Buffer.alloc`/`concat`/`from` calls below
// (buffering socket/stream/child-process bytes) need the same guarantee.
import { Buffer } from "node:buffer";

const control = new Int32Array(workerData.controlSAB);
const data = new Uint8Array(workerData.dataSAB);

// Atomics.waitAsync's promise alone does not keep this worker's event loop
// alive -- it corresponds to no libuv handle, so a worker with nothing else
// pending exits right after registering the wait, before any
// Atomics.notify can reach it (a spike finding, see spec 508 spec.md). An
// inert long-period interval holds the thread open between requests.
setInterval(() => {}, 1 << 30);

// One handle table for every long-lived resource a blocking call can open
// (spec 054 sockets, spec 452 HTTP streams, spec 450 child processes),
// keyed by an opaque handle the main thread only ever passes back. `kind`
// selects which of OP_READ/OP_READLINE/OP_WRITE/OP_CLOSE's several
// dispatches applies -- see handleOp below.
const handles = new Map();
let nextHandle = 1;

function writeResponse(status, bytes) {
  const len = bytes ? bytes.length : 0;
  if (bytes) data.set(bytes, 0);
  Atomics.store(control, P.RESP_STATUS, status);
  Atomics.store(control, P.RESP_LEN, len);
  Atomics.store(control, P.STATE, P.RESPONSE_READY);
  Atomics.notify(control, P.STATE);
}

/** process.sleep (spec 475): "at least `ms`", measured against the awake
 *  clock. A single `setTimeout` can land a hair short at the millisecond
 *  boundary -- the spike measured a 0.34ms undershoot on one of three runs
 *  -- so this measures elapsed time itself and re-arms a follow-up timer
 *  for whatever remains, rather than trusting one `setTimeout` call to have
 *  honored the request. */
async function sleepAtLeast(ms) {
  const start = performance.now();
  let remaining = ms;
  while (remaining > 0) {
    await new Promise((resolve) => setTimeout(resolve, remaining));
    remaining = ms - (performance.now() - start);
  }
}

/** Waits on `st.wake` until `ready(st)` is true. Every long-lived handle
 *  above (socket, http stream, child process) uses this same rendezvous:
 *  its event handlers call `wakeWaiter(st)` on every state change, and a
 *  pending op just re-checks its own condition each time it is woken. */
function wakeWaiter(st) {
  if (st.wake) {
    const w = st.wake;
    st.wake = null;
    w();
  }
}
/** Waits for a pure (non-mutating) boolean condition -- connected, spawned,
 *  opened -- to become true. NOT for `tryReadLine`/`tryReadRaw`/
 *  `opSocketRead` below: those consume from `st.buf` as a side effect of
 *  finding a result, so calling one as a `waitUntil` predicate and then
 *  again to fetch the value would silently drop whatever the first call
 *  already consumed. `waitFor` is the one to use with those. */
async function waitUntil(st, ready) {
  while (!ready(st)) {
    await new Promise((resolve) => {
      st.wake = resolve;
    });
  }
}

/** Waits for a state-consuming attempt (`tryReadLine`, `tryReadRaw`,
 *  `opSocketRead`) to succeed, calling it exactly once per attempt so its
 *  side effect and its return value never disagree. */
async function waitFor(st, tryFn) {
  for (;;) {
    const r = tryFn(st);
    if (r !== null) return r;
    await new Promise((resolve) => {
      st.wake = resolve;
    });
  }
}

/** Scans `st.buf` (a single growing Buffer, not the socket's array-of-chunks
 *  -- readLine needs to see across chunk boundaries) for the next "\n"-
 *  delimited line, keeping the terminator (spec 053: a blank line is "\n",
 *  only true end-of-stream is ""); a final unterminated line is returned as
 *  is once the source has ended. Shared by http.stream and
 *  child_process.spawn, whose native counterparts (`LumenHttpStream.readLine`,
 *  `LumenChildProcess.readLine`) both do exactly this over their own reader. */
function tryReadLine(st) {
  const nl = st.buf.indexOf(10);
  if (nl >= 0) {
    const line = st.buf.subarray(0, nl + 1);
    st.buf = Buffer.from(st.buf.subarray(nl + 1));
    return line;
  }
  if (st.ended || st.pendingErr) {
    if (st.buf.length === 0) return Buffer.alloc(0);
    const rest = st.buf;
    st.buf = Buffer.alloc(0);
    return rest;
  }
  return null;
}

/** The next raw chunk off `st.buf` (spec 452's `read()`, spec 495's
 *  binary-frame use case): whatever is buffered, no delimiter scan, "" once
 *  the source has ended. */
function tryReadRaw(st) {
  if (st.buf.length > 0) {
    const out = st.buf;
    st.buf = Buffer.alloc(0);
    return out;
  }
  if (st.ended || st.pendingErr) return Buffer.alloc(0);
  return null;
}

function appendBuf(st, chunk) {
  st.buf = st.buf.length === 0 ? Buffer.from(chunk) : Buffer.concat([st.buf, chunk]);
}

// ---------------------------------------------------------------------------
// net.connect / Socket (spec 054).

async function opConnect(argBytes) {
  const { host, port } = P.decodeConnectArgs(argBytes);
  // Every listener is attached in the SAME synchronous call that creates
  // the socket, not after awaiting a connect promise: a fast peer (write
  // then end, both synchronous on its side) can deliver data and EOF
  // before a promise continuation (a microtask) gets to run, so listeners
  // attached one tick later can miss both (a spike finding, see spec 508
  // spec.md).
  const h = nextHandle++;
  const st = { kind: "socket", sock: null, buf: [], ended: false, pendingErr: null, wake: null, connectErr: null, connected: false };
  handles.set(h, st);
  const wake = () => wakeWaiter(st);
  const sock = net.connect(port, host);
  st.sock = sock;
  sock.on("connect", () => { st.connected = true; wake(); });
  sock.on("data", (chunk) => { st.buf.push(chunk); wake(); });
  sock.on("end", () => { st.ended = true; wake(); });
  sock.on("error", (e) => { if (!st.connected) st.connectErr = e; else st.pendingErr = e; wake(); });
  await waitUntil(st, (s) => s.connected || s.connectErr);
  if (st.connectErr) {
    handles.delete(h);
    // Never a hard failure: LumenSocket.__init(io, null) on a failed
    // connect degrades to "always read empty, write is a no-op" rather
    // than throwing (src/lumen_runtime_net.zig's `__netConnect`) -- the
    // sentinel handle -1 gets the same treatment at the sync_bridge layer.
    return { status: -1, bytes: null };
  }
  return { status: 0, bytes: P.encodeConnectResult(h) };
}

function opSocketRead(st) {
  if (st.buf.length === 0 && !st.ended && !st.pendingErr) return null;
  if (st.pendingErr) return { status: -2, bytes: Buffer.alloc(0) };
  let out = Buffer.concat(st.buf);
  st.buf = [];
  if (out.length > P.DATA_BYTES) {
    st.buf = [out.subarray(P.DATA_BYTES)];
    out = out.subarray(0, P.DATA_BYTES);
  }
  return { status: out.length === 0 && st.ended ? 1 : 0, bytes: out };
}

// ---------------------------------------------------------------------------
// http.request / http.get (spec 042): one buffered round trip, no handle.

function nodeHttpModule(url) {
  return url.startsWith("https://") ? https : http;
}

/** Runs one buffered HTTP request to completion, capped at `P.DATA_BYTES` of
 *  response body (past that, the request is aborted and reported the same
 *  way a connect/TLS failure is -- degrade to a fallback value, never
 *  crash or hang; spec 452's `http.stream` is the way to read a response
 *  too big to buffer). Never rejects: every failure resolves the same
 *  `{ status: -1, ok: false, body: Buffer.alloc(0) }` the native runtime's
 *  `__httpRequest` falls back to on a failed fetch. */
function httpRequestOnce(url, method, body, headers) {
  return new Promise((resolvePromise) => {
    // Every path below resolves through here exactly once: destroying the
    // request mid-response (the size-cap path) does not reliably raise a
    // matching "end"/"error" on `res`, so relying on those alone risks a
    // hang -- resolve at the moment failure is detected instead, and make
    // every later event into this same request a no-op.
    let settled = false;
    const resolve = (v) => {
      if (settled) return;
      settled = true;
      resolvePromise(v);
    };
    const FAIL = { status: -1, ok: false, body: Buffer.alloc(0) };
    let mod, opts;
    try {
      const u = new URL(url);
      mod = nodeHttpModule(url);
      opts = { method, headers: Object.fromEntries(headers), hostname: u.hostname, port: u.port, path: u.pathname + u.search };
    } catch {
      resolve(FAIL);
      return;
    }
    const req = mod.request(opts, (res) => {
      const chunks = [];
      let total = 0;
      res.on("data", (chunk) => {
        total += chunk.length;
        if (total > P.DATA_BYTES) { resolve(FAIL); req.destroy(); return; }
        chunks.push(chunk);
      });
      res.on("end", () => {
        const status = res.statusCode ?? -1;
        resolve({ status, ok: status >= 200 && status < 300, body: Buffer.concat(chunks) });
      });
      res.on("error", () => resolve(FAIL));
    });
    req.on("error", () => resolve(FAIL));
    if (body.length > 0) req.write(body);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// http.stream (spec 452): a live read handle over a response in progress.

async function opHttpStreamOpen(argBytes) {
  const { url, method, body, headers } = P.decodeHttpOpenArgs(argBytes);
  const h = nextHandle++;
  const st = { kind: "http", buf: Buffer.alloc(0), ended: false, pendingErr: null, wake: null, opened: false, openErr: false, status: -1, headers: new Map(), req: null, socket: null };
  handles.set(h, st);
  let mod, opts;
  try {
    const u = new URL(url);
    mod = nodeHttpModule(url);
    const hdrs = Object.fromEntries(headers);
    // Declines a compressed transfer so the bytes read here are the wire
    // bytes a line-oriented reader (readLine, for SSE) or a raw reader
    // (read, for a websocket frame) expects, matching
    // src/lumen_runtime_net.zig's __httpStreamOpen comment.
    if (!Object.keys(hdrs).some((k) => k.toLowerCase() === "accept-encoding")) hdrs["Accept-Encoding"] = "identity";
    opts = { method, headers: hdrs, hostname: u.hostname, port: u.port, path: u.pathname + u.search };
  } catch {
    handles.delete(h);
    return { status: -1, bytes: null };
  }
  const req = mod.request(opts);
  st.req = req;
  req.on("socket", (sock) => { st.socket = sock; });
  req.on("upgrade", (res, socket, head) => {
    st.status = res.statusCode;
    st.headers = new Map(Object.entries(res.headers).map(([k, v]) => [k, Array.isArray(v) ? v.join(", ") : v]));
    st.socket = socket;
    if (head.length > 0) appendBuf(st, head);
    socket.on("data", (chunk) => { appendBuf(st, chunk); wakeWaiter(st); });
    socket.on("end", () => { st.ended = true; wakeWaiter(st); });
    socket.on("error", (e) => { st.pendingErr = e; wakeWaiter(st); });
    st.opened = true;
    wakeWaiter(st);
  });
  req.on("response", (res) => {
    st.status = res.statusCode ?? -1;
    st.headers = new Map(Object.entries(res.headers).map(([k, v]) => [k, Array.isArray(v) ? v.join(", ") : v]));
    res.on("data", (chunk) => { appendBuf(st, chunk); wakeWaiter(st); });
    res.on("end", () => { st.ended = true; wakeWaiter(st); });
    res.on("error", (e) => { st.pendingErr = e; wakeWaiter(st); });
    st.opened = true;
    wakeWaiter(st);
  });
  // A connection error before the response/upgrade arrives fails the open
  // (a dead handle, below); one after arrival must instead unblock a
  // pending readLine()/read() the way a socket's own "error" does, or a
  // dropped mid-stream connection would hang the reader forever.
  req.on("error", (e) => {
    if (!st.opened) { st.openErr = true; wakeWaiter(st); }
    else { st.pendingErr = e; wakeWaiter(st); }
  });
  if (body.length > 0) req.write(body);
  req.end();
  await waitUntil(st, (s) => s.opened || s.openErr);
  if (st.openErr) {
    handles.delete(h);
    // Same fallback convention as a failed connect/spawn: a dead handle,
    // never a thrown error (src/lumen_runtime_net.zig's __httpStreamOpen
    // comment: "Any open/connect/TLS failure degrades to a handle with
    // status -1 and done() true").
    return { status: -1, bytes: null };
  }
  return { status: 0, bytes: P.encodeConnectResult(h) };
}

// ---------------------------------------------------------------------------
// child_process.spawn (spec 450).

async function opSpawn(argBytes) {
  // `command`/`args` cross the wire as the Lumen (latin1-per-byte) strings
  // they are; `text(...)` is the same latin1-bytes -> real-JS-text step
  // `lib/child_process.mjs`'s own `spawnSync` applies directly, done here
  // instead because the whole point of sending the raw bytes across is to
  // decode them exactly once, on the side that actually calls spawn.
  const { command: rawCommand, args: rawArgs } = P.decodeSpawnArgs(argBytes);
  const command = text(rawCommand);
  const args = rawArgs.map(text);
  const h = nextHandle++;
  // stderr is INHERITED, not piped, mirroring src/lumen_runtime_os.zig's
  // LumenChildProcess exactly: readLine only drains stdout, so an
  // undrained stderr pipe would deadlock the child once it backs up. The
  // broker worker shares the main thread's stderr fd, so this reaches the
  // same terminal a native build's inherited stderr would.
  let child;
  try {
    child = nodeSpawn(command, args, { stdio: ["pipe", "pipe", "inherit"] });
  } catch {
    handles.delete(h);
    return { status: -1, bytes: null };
  }
  const st = { kind: "child", buf: Buffer.alloc(0), ended: false, pendingErr: null, wake: null, child, alive: true, spawnErr: false, spawned: false };
  handles.set(h, st);
  child.on("spawn", () => { st.spawned = true; wakeWaiter(st); });
  child.on("error", (e) => { if (!st.spawned) st.spawnErr = true; else st.pendingErr = e; wakeWaiter(st); });
  child.stdout.on("data", (chunk) => { appendBuf(st, chunk); wakeWaiter(st); });
  // Only the stdout stream's own "end" marks EOF for readLine() -- not the
  // child's "exit", which can fire while stdout still has buffered data
  // draining through the pipe. Native's blocking wait() (LumenChildProcess
  // .close, src/lumen_runtime_os.zig) has no such race: the OS pipe's real
  // EOF is what readLine's own reader reaches.
  child.stdout.on("end", () => { st.ended = true; wakeWaiter(st); });
  await waitUntil(st, (s) => s.spawned || s.spawnErr);
  if (st.spawnErr) {
    handles.delete(h);
    // A failed spawn degrades to a no-op handle, the same convention
    // LumenSocket's `stream: ?...` uses (src/lumen_runtime_os.zig comment
    // on LumenChildProcess).
    return { status: -1, bytes: null };
  }
  return { status: 0, bytes: P.encodeConnectResult(h) };
}

/** Mirrors `LumenChildProcess.close` exactly (src/lumen_runtime_os.zig):
 *  flush/close stdin, then BLOCK until the child actually exits -- it does
 *  not kill it. Idempotent via `st.alive`. */
async function closeChild(st) {
  if (!st.alive) return;
  st.alive = false;
  try { st.child.stdin.end(); } catch {}
  if (st.child.exitCode !== null || st.child.signalCode !== null) return;
  await new Promise((resolve) => st.child.once("exit", resolve));
}

// ---------------------------------------------------------------------------
// The dispatcher. OP_READ/OP_READLINE/OP_WRITE/OP_WRITELINE/OP_CLOSE are
// generic across handle kinds; each op below picks its behavior from
// `st.kind`.

async function handleOp(op, argBytes) {
  if (op === P.OP_SLEEP) {
    await sleepAtLeast(P.decodeSleepArgs(argBytes));
    return { status: 0, bytes: null };
  }
  if (op === P.OP_CONNECT) return opConnect(argBytes);
  if (op === P.OP_SPAWN) return opSpawn(argBytes);
  if (op === P.OP_HTTP_STREAM_OPEN) return opHttpStreamOpen(argBytes);
  if (op === P.OP_HTTP_REQUEST) {
    const { url, method, body, headers } = P.decodeHttpOpenArgs(argBytes);
    const { status, ok, body: respBody } = await httpRequestOnce(url, method, body, headers);
    return { status: 0, bytes: P.encodeHttpResponseResult(status, ok, respBody) };
  }

  if (op === P.OP_READ) {
    const handle = P.decodeHandleArgs(argBytes);
    const st = handles.get(handle);
    if (!st) return { status: -1, bytes: null };
    if (st.kind === "socket") return waitFor(st, opSocketRead);
    // http (raw read, spec 452/495): the same buffer readLine() scans.
    const out = await waitFor(st, tryReadRaw);
    return { status: 0, bytes: out };
  }

  if (op === P.OP_READLINE) {
    const handle = P.decodeHandleArgs(argBytes);
    const st = handles.get(handle);
    if (!st) return { status: -1, bytes: null };
    const line = await waitFor(st, tryReadLine);
    return { status: 0, bytes: line };
  }

  if (op === P.OP_WRITE || op === P.OP_WRITELINE) {
    const { handle, payload } = P.decodeWriteArgs(argBytes);
    const st = handles.get(handle);
    if (!st) return { status: -1, bytes: null };
    if (st.kind === "socket") {
      await new Promise((resolve) => st.sock.write(payload, resolve));
    } else if (st.kind === "child") {
      if (st.alive && st.child.stdin.writable) {
        // One write, not two: a second `.write("\n")` call's callback would
        // fire independently of this op's own resolve, so the op could
        // report done before the newline actually left the process.
        const out = op === P.OP_WRITELINE ? Buffer.concat([payload, Buffer.from("\n")]) : payload;
        await new Promise((resolve) => st.child.stdin.write(out, resolve));
      }
    } else if (st.kind === "http") {
      // spec 494: raw bytes on the connection past a 101 upgrade. Before
      // any socket is known (no upgrade yet, no response yet) this is a
      // no-op, matching the dead-handle fallback convention elsewhere.
      if (st.socket) await new Promise((resolve) => st.socket.write(payload, resolve));
    }
    return { status: 0, bytes: null };
  }

  if (op === P.OP_HTTP_STATUS) {
    const handle = P.decodeHandleArgs(argBytes);
    const st = handles.get(handle);
    return { status: 0, bytes: P.encodeStatusResult(st ? st.status : -1) };
  }
  if (op === P.OP_HTTP_HEADER) {
    const { handle, name } = P.decodeHeaderArgs(argBytes);
    const st = handles.get(handle);
    if (!st) return { status: 0, bytes: Buffer.alloc(0) };
    const lower = name.toLowerCase();
    for (const [k, v] of st.headers) if (k.toLowerCase() === lower) return { status: 0, bytes: Buffer.from(v, "latin1") };
    return { status: 0, bytes: Buffer.alloc(0) };
  }
  if (op === P.OP_HTTP_DONE) {
    const handle = P.decodeHandleArgs(argBytes);
    const st = handles.get(handle);
    const done = !st || (st.buf.length === 0 && (st.ended || !!st.pendingErr));
    return { status: 0, bytes: P.encodeBoolResult(done) };
  }

  if (op === P.OP_CLOSE) {
    const handle = P.decodeHandleArgs(argBytes);
    const st = handles.get(handle);
    if (st) {
      if (st.kind === "socket") st.sock.destroy();
      else if (st.kind === "child") await closeChild(st);
      else if (st.kind === "http") { try { st.req.destroy(); } catch {} }
      handles.delete(handle);
    }
    return { status: 0, bytes: null };
  }
  return { status: -99, bytes: null };
}

async function listenLoop() {
  for (;;) {
    // Wait without blocking this thread's own event loop: real socket
    // callbacks and timers above keep firing while this is pending.
    const w = Atomics.waitAsync(control, P.STATE, P.IDLE);
    if (w.async) await w.value;
    if (Atomics.load(control, P.STATE) !== P.REQUEST_POSTED) continue;
    const op = Atomics.load(control, P.OP);
    const argLen = Atomics.load(control, P.ARG_LEN);
    const argBytes = data.slice(0, argLen);
    const { status, bytes } = await handleOp(op, argBytes);
    writeResponse(status, bytes);
  }
}

listenLoop();
parentPort.postMessage("ready");

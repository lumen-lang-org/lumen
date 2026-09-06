// The broker worker: the only thread that ever touches real sockets/timers.
// Owns the async world; the main thread never runs an event loop tick while
// a request is outstanding, so this is the only place that can.
import { parentPort, workerData } from 'node:worker_threads';
import net from 'node:net';
import * as P from './protocol.mjs';

const control = new Int32Array(workerData.controlSAB);
const data = new Uint8Array(workerData.dataSAB);

// Atomics.waitAsync's promise alone does not keep this worker's event loop
// alive (a documented Node/V8 gotcha -- it corresponds to no libuv handle),
// so an inert long-period interval holds the thread open between requests.
setInterval(() => {}, 1 << 30);

const sockets = new Map();
let nextHandle = 1;

function writeResponse(status, bytes) {
  const len = bytes ? bytes.length : 0;
  if (bytes) data.set(bytes, 0);
  Atomics.store(control, P.RESP_STATUS, status);
  Atomics.store(control, P.RESP_LEN, len);
  Atomics.store(control, P.STATE, P.RESPONSE_READY);
  Atomics.notify(control, P.STATE);
}

async function handle(op, argBytes) {
  const args = argBytes.length ? JSON.parse(Buffer.from(argBytes).toString('utf8')) : {};
  if (op === P.OP_SLEEP) {
    await new Promise((r) => setTimeout(r, args.ms));
    return { status: 0, bytes: null };
  }
  if (op === P.OP_CONNECT) {
    // Every listener is attached in the SAME synchronous call that creates
    // the socket, not after awaiting a connect promise: a fast peer (write
    // + end, all synchronous on its side) can deliver data and EOF before
    // a promise continuation (a microtask) gets to run, so attaching
    // listeners one tick later can miss them entirely.
    const h = nextHandle++;
    const st = { sock: null, buf: [], ended: false, pendingErr: null, wake: null, connectErr: null, connected: false };
    sockets.set(h, st);
    const wakeWaiter = () => { if (st.wake) { const w = st.wake; st.wake = null; w(); } };
    const sock = net.connect(args.port, args.host);
    st.sock = sock;
    sock.on('connect', () => { st.connected = true; wakeWaiter(); });
    sock.on('data', (chunk) => { st.buf.push(chunk); wakeWaiter(); });
    sock.on('end', () => { st.ended = true; wakeWaiter(); });
    sock.on('error', (e) => { if (!st.connected) st.connectErr = e; else st.pendingErr = e; wakeWaiter(); });
    while (!st.connected && !st.connectErr) {
      await new Promise((r) => { st.wake = r; });
    }
    if (st.connectErr) { sockets.delete(h); return { status: -3, bytes: null }; }
    return { status: 0, bytes: Buffer.from(JSON.stringify({ handle: h })) };
  }
  if (op === P.OP_READ) {
    const st = sockets.get(args.handle);
    if (!st) return { status: -1, bytes: null };
        while (st.buf.length === 0 && !st.ended && !st.pendingErr) {
      await new Promise((r) => { st.wake = r; });
    }
    if (st.pendingErr) return { status: -2, bytes: null };
    let out = Buffer.concat(st.buf);
    st.buf = [];
    if (out.length > P.DATA_BYTES) {
      st.buf = [out.subarray(P.DATA_BYTES)];
      out = out.subarray(0, P.DATA_BYTES);
    }
    return { status: out.length === 0 && st.ended ? 1 : 0, bytes: out };
  }
  if (op === P.OP_WRITE) {
    const st = sockets.get(args.handle);
    if (!st) return { status: -1, bytes: null };
    const payload = Buffer.from(args.dataB64, 'base64');
    await new Promise((resolve) => st.sock.write(payload, resolve));
    return { status: 0, bytes: null };
  }
  if (op === P.OP_CLOSE) {
    const st = sockets.get(args.handle);
    if (st) { st.sock.destroy(); sockets.delete(args.handle); }
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
    const { status, bytes } = await handle(op, argBytes);
    writeResponse(status, bytes);
  }
}

listenLoop();
parentPort.postMessage('ready');

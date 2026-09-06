// The broker worker (spec 508): the only thread that ever touches a real
// socket or timer for a blocking call. It owns the async world, so the main
// thread never needs to run its own event loop tick while a request is
// outstanding -- this is the only place that safely could anyway.
import { parentPort, workerData } from "node:worker_threads";
import net from "node:net";
import * as P from "./protocol.mjs";

const control = new Int32Array(workerData.controlSAB);
const data = new Uint8Array(workerData.dataSAB);

// Atomics.waitAsync's promise alone does not keep this worker's event loop
// alive -- it corresponds to no libuv handle, so a worker with nothing else
// pending exits right after registering the wait, before any
// Atomics.notify can reach it (a spike finding, see spec 508 spec.md). An
// inert long-period interval holds the thread open between requests.
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

async function handleOp(op, argBytes) {
  if (op === P.OP_SLEEP) {
    await sleepAtLeast(P.decodeSleepArgs(argBytes));
    return { status: 0, bytes: null };
  }
  if (op === P.OP_CONNECT) {
    const { host, port } = P.decodeConnectArgs(argBytes);
    // Every listener is attached in the SAME synchronous call that creates
    // the socket, not after awaiting a connect promise: a fast peer (write
    // then end, both synchronous on its side) can deliver data and EOF
    // before a promise continuation (a microtask) gets to run, so listeners
    // attached one tick later can miss both (a spike finding, see spec 508
    // spec.md).
    const h = nextHandle++;
    const st = { sock: null, buf: [], ended: false, pendingErr: null, wake: null, connectErr: null, connected: false };
    sockets.set(h, st);
    const wakeWaiter = () => {
      if (st.wake) {
        const w = st.wake;
        st.wake = null;
        w();
      }
    };
    const sock = net.connect(port, host);
    st.sock = sock;
    sock.on("connect", () => { st.connected = true; wakeWaiter(); });
    sock.on("data", (chunk) => { st.buf.push(chunk); wakeWaiter(); });
    sock.on("end", () => { st.ended = true; wakeWaiter(); });
    sock.on("error", (e) => { if (!st.connected) st.connectErr = e; else st.pendingErr = e; wakeWaiter(); });
    while (!st.connected && !st.connectErr) {
      await new Promise((resolve) => { st.wake = resolve; });
    }
    if (st.connectErr) {
      sockets.delete(h);
      return { status: -3, bytes: null };
    }
    return { status: 0, bytes: P.encodeConnectResult(h) };
  }
  if (op === P.OP_READ) {
    const handle = P.decodeHandleArgs(argBytes);
    const st = sockets.get(handle);
    if (!st) return { status: -1, bytes: null };
    while (st.buf.length === 0 && !st.ended && !st.pendingErr) {
      await new Promise((resolve) => { st.wake = resolve; });
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
    const { handle, payload } = P.decodeWriteArgs(argBytes);
    const st = sockets.get(handle);
    if (!st) return { status: -1, bytes: null };
    await new Promise((resolve) => st.sock.write(payload, resolve));
    return { status: 0, bytes: null };
  }
  if (op === P.OP_CLOSE) {
    const handle = P.decodeHandleArgs(argBytes);
    const st = sockets.get(handle);
    if (st) {
      st.sock.destroy();
      sockets.delete(handle);
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

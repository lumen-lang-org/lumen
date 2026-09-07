// One control block and one broker worker per program (spec 508 T003), not
// per call site: started lazily on first use so a program that never
// reaches a blocking surface never pays for the worker, then shared by
// every blocking call the program makes afterward.
import { Worker } from "node:worker_threads";
import * as P from "./protocol.mjs";
// The real Node `Buffer`, not the ambient global -- see protocol.mjs's own
// comment: `globals.mjs` replaces `globalThis.Buffer` with `LumenBuffer`
// (spec 056) on this (the calling) thread for every Lumen program.
import { Buffer } from "node:buffer";

let instance = null;

function start() {
  const controlSAB = new SharedArrayBuffer(P.CONTROL_WORDS * 4);
  const dataSAB = new SharedArrayBuffer(P.DATA_BYTES);
  const brokerUrl = new URL("./broker.mjs", import.meta.url);
  const worker = new Worker(brokerUrl, { workerData: { controlSAB, dataSAB } });
  worker.unref();
  return { control: new Int32Array(controlSAB), data: new Uint8Array(dataSAB), worker, reqId: 0 };
}

function broker() {
  return (instance ??= start());
}

// listenerId -> callback(handle, controlSAB, dataSAB), registered by
// `net.createServer`/`http.createServer` (spec 511). One `message`
// listener on the broker worker, routing by `listenerId`, rather than one
// per `createServer` call: `Worker` only ever needs a single `on("message")`
// subscription regardless of how many listeners the program opens.
const acceptHandlers = new Map();
let messageListenerAttached = false;

function ensureMessageListener() {
  if (messageListenerAttached) return;
  messageListenerAttached = true;
  broker().worker.on("message", (msg) => {
    if (!msg || !msg.lumenAccept) return;
    const cb = acceptHandlers.get(msg.listenerId);
    if (cb) cb(msg.handle, msg.controlSAB, msg.dataSAB);
  });
}

/** Registers `onConn(handle, controlSAB, dataSAB)` to run for every
 *  connection `broker.mjs`'s `opListen` accepts on `listenerId` (the value
 *  `OP_LISTEN`'s response returns). Never unregistered -- a listener runs
 *  for the life of the program, matching native's `noreturn`
 *  `http.createServer`.
 *
 *  Also `ref()`s the broker worker, undoing `start()`'s own `unref()`: every
 *  other blocking call is a bounded request the CALLING thread's own
 *  synchronous wait already keeps the process alive for, but a server has
 *  no such wait -- `net.createServer(...)`'s call returns immediately
 *  (having registered the handler) and the calling thread's synchronous
 *  code moves on, same as native's own accept loop running on a spawned
 *  thread while the caller continues. Without this, a program (or a
 *  `Worker.run(listenerFn)` thread, exactly Joule's own pattern) whose
 *  remaining work is "wait for accepted connections" would fall idle and
 *  exit the moment its own top-level script finishes, taking the listener
 *  down with it despite never being told to stop. */
export function onAccept(listenerId, onConn) {
  ensureMessageListener();
  acceptHandlers.set(listenerId, onConn);
  broker().worker.ref();
}

/** The non-blocking, per-handle counterpart to `call()` (spec 511): posts
 *  a request the same way, but awaits the response via `Atomics.waitAsync`
 *  instead of `Atomics.wait`, so the calling thread's event loop stays free
 *  to run other handles' pending calls, timers and I/O while this one is
 *  outstanding -- proven in isolation by the T001 spike
 *  (`packages/node-runtime/spike/511-concurrent-handles/`). Scoped to its
 *  own `controlSAB`/`dataSAB` (one per live handle, allocated by the broker
 *  at accept time -- see `broker.mjs`'s `opListen`/`serviceHandle`), never
 *  the shared process-wide control block `call()` uses, so unlike `call()`
 *  this never touches `broker()`/`instance` at all. */
export async function callHandle(controlSAB, dataSAB, op, argBytes) {
  const control = new Int32Array(controlSAB);
  const data = new Uint8Array(dataSAB);
  data.set(argBytes, 0);
  Atomics.store(control, P.ARG_LEN, argBytes.length);
  Atomics.store(control, P.OP, op);
  Atomics.store(control, P.STATE, P.REQUEST_POSTED);
  Atomics.notify(control, P.STATE);

  const w = Atomics.waitAsync(control, P.STATE, P.REQUEST_POSTED);
  if (w.async) await w.value;
  const status = Atomics.load(control, P.RESP_STATUS);
  const len = Atomics.load(control, P.RESP_LEN);
  const bytes = Buffer.from(data.slice(0, len));
  Atomics.store(control, P.STATE, P.IDLE);
  return { status, bytes };
}

/** Posts one request and blocks this thread (via `Atomics.wait`, so no
 *  timer, I/O callback or console.log flush runs on this thread until the
 *  broker answers) until the broker's response is ready. `argBytes` and the
 *  returned `bytes` are raw payloads over the shared data region -- callers
 *  own their op's own encoding, see `protocol.mjs`. */
export function call(op, argBytes, timeoutMs) {
  const b = broker();
  b.data.set(argBytes, 0);
  Atomics.store(b.control, P.ARG_LEN, argBytes.length);
  Atomics.store(b.control, P.OP, op);
  Atomics.store(b.control, P.REQ_ID, ++b.reqId);
  Atomics.store(b.control, P.STATE, P.REQUEST_POSTED);
  Atomics.notify(b.control, P.STATE);

  const r = Atomics.wait(b.control, P.STATE, P.REQUEST_POSTED, timeoutMs ?? Infinity);
  if (r === "timed-out") throw new Error("lumen node broker: no response in time");
  const status = Atomics.load(b.control, P.RESP_STATUS);
  const len = Atomics.load(b.control, P.RESP_LEN);
  const bytes = Buffer.from(b.data.slice(0, len));
  Atomics.store(b.control, P.STATE, P.IDLE);
  return { status, bytes };
}

/** Terminates the broker worker, if one was ever started. Real programs let
 *  the (unref'd) worker exit with the process; this is for tests that start
 *  and stop several brokers in one process.
 *
 *  Also resets `messageListenerAttached` -- found for real, not
 *  hypothetically, by a full multi-file `node --test` run hanging forever
 *  on a `net.createServer` call that came after an earlier test file's own
 *  `shutdownBridge()`: `ensureMessageListener` only ever attaches its
 *  "message" listener to whichever worker was live the FIRST time any
 *  `net.createServer`/`http.createServer` call reached it, keyed by this
 *  module-level flag rather than by worker identity. A later
 *  `shutdownBroker()` swaps in a brand new `Worker` (`broker()`'s
 *  `instance ??= start()`) but left the flag set, so `ensureMessageListener`
 *  saw "already attached" and skipped the new worker entirely -- every
 *  connection it ever accepted then had nowhere to route its `postMessage`,
 *  hanging the accept callback forever. Resetting the flag here makes the
 *  next `onAccept` re-attach to whichever worker is actually current. */
export function shutdownBroker() {
  if (instance) {
    instance.worker.terminate();
    instance = null;
    messageListenerAttached = false;
  }
}

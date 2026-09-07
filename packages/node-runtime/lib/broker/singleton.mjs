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
 *  and stop several brokers in one process. */
export function shutdownBroker() {
  if (instance) {
    instance.worker.terminate();
    instance = null;
  }
}

// The broker worker for spec 511's T001 spike: one independent async loop
// PER HANDLE, each waiting on its own control block. Unlike spec 508's
// broker.mjs (one listenLoop() over one shared control block, so the loop
// must fully answer request N -- write the response, notify -- before it
// can even look at request N+1), N of these loops run concurrently on this
// same worker thread: none of them ever call Atomics.wait (which really
// would serialize them, blocking this whole thread), only Atomics.waitAsync,
// so the JS event loop freely interleaves them.
import { parentPort, workerData } from 'node:worker_threads';
import * as P from './protocol.mjs';

// Same gotcha spec 508's spike found for Atomics.waitAsync: its promise
// alone does not keep this worker's event loop alive (corresponds to no
// libuv handle), so an inert long-period interval holds the thread open.
setInterval(() => {}, 1 << 30);

async function serviceHandle(handleId, controlSAB, dataSAB) {
  const control = new Int32Array(controlSAB);
  const data = new Uint8Array(dataSAB);
  for (;;) {
    const w = Atomics.waitAsync(control, P.STATE, P.IDLE);
    if (w.async) await w.value;
    if (Atomics.load(control, P.STATE) !== P.REQUEST_POSTED) continue;
    const op = Atomics.load(control, P.OP);
    const argLen = Atomics.load(control, P.ARG_LEN);
    const argBytes = data.slice(0, argLen);
    const args = JSON.parse(Buffer.from(argBytes).toString('utf8'));

    let status = 0;
    let bytes = new Uint8Array(0);
    if (op === P.OP_SLEEP_ECHO) {
      await new Promise((r) => setTimeout(r, args.ms));
      bytes = Buffer.from(JSON.stringify({ tag: args.tag, handleId }));
    } else {
      status = -99;
    }

    data.set(bytes, 0);
    Atomics.store(control, P.RESP_STATUS, status);
    Atomics.store(control, P.RESP_LEN, bytes.length);
    Atomics.store(control, P.STATE, P.RESPONSE_READY);
    Atomics.notify(control, P.STATE);
  }
}

// workerData.handles: [{ handleId, controlSAB, dataSAB }, ...] -- a fixed
// set for the spike; the real broker (tasks.md T003) registers these
// dynamically as connections are accepted/opened.
for (const h of workerData.handles) {
  serviceHandle(h.handleId, h.controlSAB, h.dataSAB);
}

parentPort.postMessage('ready');

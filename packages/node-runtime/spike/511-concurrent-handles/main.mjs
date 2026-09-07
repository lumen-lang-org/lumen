// T001's actual proof: two handles, each with its own control/data pair,
// both with an outstanding request at once, neither serialized behind the
// other and neither blocking this (the main) thread's own event loop.
// Run: node packages/node-runtime/spike/511-concurrent-handles/main.mjs
import { Worker } from 'node:worker_threads';
import * as P from './protocol.mjs';

function makeHandle(handleId) {
  const controlSAB = new SharedArrayBuffer(P.CONTROL_WORDS * 4);
  const dataSAB = new SharedArrayBuffer(P.DATA_BYTES);
  return { handleId, controlSAB, dataSAB, control: new Int32Array(controlSAB), data: new Uint8Array(dataSAB) };
}

// The non-blocking, per-handle counterpart to spec 508's singleton.mjs
// `call()`: posts the request the same way, then awaits the response via
// Atomics.waitAsync instead of Atomics.wait, so THIS (calling) thread's
// event loop is free to run other handles' pending calls, timers, and I/O
// while this one is outstanding.
async function callHandleAsync(h, op, args) {
  const argBytes = Buffer.from(JSON.stringify(args));
  h.data.set(argBytes, 0);
  Atomics.store(h.control, P.ARG_LEN, argBytes.length);
  Atomics.store(h.control, P.OP, op);
  Atomics.store(h.control, P.STATE, P.REQUEST_POSTED);
  Atomics.notify(h.control, P.STATE);

  const w = Atomics.waitAsync(h.control, P.STATE, P.REQUEST_POSTED);
  if (w.async) await w.value;
  const status = Atomics.load(h.control, P.RESP_STATUS);
  const len = Atomics.load(h.control, P.RESP_LEN);
  const bytes = Buffer.from(h.data.slice(0, len));
  Atomics.store(h.control, P.STATE, P.IDLE);
  return { status, result: JSON.parse(bytes.toString('utf8')) };
}

async function main() {
  const A = makeHandle('A'); // slow: 500ms
  const B = makeHandle('B'); // fast: 50ms

  const worker = new Worker(new URL('./broker.mjs', import.meta.url), {
    workerData: { handles: [A, B].map((h) => ({ handleId: h.handleId, controlSAB: h.controlSAB, dataSAB: h.dataSAB })) },
  });
  await new Promise((resolve) => worker.once('message', resolve));

  const events = [];
  let timerFiredWhilePending = false;
  const pendingTimer = setTimeout(() => { timerFiredWhilePending = true; }, 10);

  const callA = callHandleAsync(A, P.OP_SLEEP_ECHO, { ms: 500, tag: 'from-A' }).then((r) => {
    events.push({ at: Date.now(), who: 'A', r });
  });
  const callB = callHandleAsync(B, P.OP_SLEEP_ECHO, { ms: 50, tag: 'from-B' }).then((r) => {
    events.push({ at: Date.now(), who: 'B', r });
  });

  await Promise.all([callA, callB]);
  clearTimeout(pendingTimer);
  await worker.terminate();

  // 1. The main thread's own timer (10ms) must have fired while both calls
  //    (500ms, 50ms) were still outstanding -- proves Atomics.waitAsync did
  //    not block this thread's event loop the way Atomics.wait would have.
  const check1 = timerFiredWhilePending;
  // 2. B (50ms) must resolve strictly before A (500ms) -- proves the two
  //    handles' requests ran concurrently, not serialized in submission
  //    order (which would answer A first regardless of its own delay).
  const check2 = events[0]?.who === 'B' && events[1]?.who === 'A';
  // 3. Each handle's response carries its OWN tag/handleId -- proves no
  //    cross-talk between the two handles' independent control blocks.
  const check3 =
    events.find((e) => e.who === 'A').r.result.tag === 'from-A' &&
    events.find((e) => e.who === 'A').r.result.handleId === 'A' &&
    events.find((e) => e.who === 'B').r.result.tag === 'from-B' &&
    events.find((e) => e.who === 'B').r.result.handleId === 'B';

  console.log('check1 (main-thread timer fired while both pending):', check1);
  console.log('check2 (B resolved before A, not FIFO-serialized):    ', check2);
  console.log("check3 (each response carries its own handle's tag):  ", check3);

  const ok = check1 && check2 && check3;
  console.log(ok ? '\nT001 SPIKE: PASS' : '\nT001 SPIKE: FAIL');
  process.exit(ok ? 0 : 1);
}

main();

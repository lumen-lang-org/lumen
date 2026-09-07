// Edge case plan.md's T001 flags: does the MAIN thread need its own
// keep-alive when the only outstanding work is an awaited
// Atomics.waitAsync, with no other timer/handle holding the process open?
import { Worker } from 'node:worker_threads';
import * as P from './protocol.mjs';

async function main() {
  const controlSAB = new SharedArrayBuffer(P.CONTROL_WORDS * 4);
  const dataSAB = new SharedArrayBuffer(P.DATA_BYTES);
  const control = new Int32Array(controlSAB);
  const data = new Uint8Array(dataSAB);

  const worker = new Worker(new URL('./broker.mjs', import.meta.url), {
    workerData: { handles: [{ handleId: 'X', controlSAB, dataSAB }] },
  });
  await new Promise((resolve) => worker.once('message', resolve));

  const started = Date.now();
  const argBytes = Buffer.from(JSON.stringify({ ms: 300, tag: 'solo' }));
  data.set(argBytes, 0);
  Atomics.store(control, P.ARG_LEN, argBytes.length);
  Atomics.store(control, P.OP, P.OP_SLEEP_ECHO);
  Atomics.store(control, P.STATE, P.REQUEST_POSTED);
  Atomics.notify(control, P.STATE);

  // Nothing else is pending on this thread right now -- no timer, no other
  // promise -- just this one await.
  const w = Atomics.waitAsync(control, P.STATE, P.REQUEST_POSTED);
  if (w.async) await w.value;
  const elapsed = Date.now() - started;
  const status = Atomics.load(control, P.RESP_STATUS);
  const len = Atomics.load(control, P.RESP_LEN);
  const result = JSON.parse(Buffer.from(data.slice(0, len)).toString('utf8'));

  await worker.terminate();
  const ok = status === 0 && result.tag === 'solo' && elapsed >= 290;
  console.log('elapsed:', elapsed, 'status:', status, 'result:', result);
  console.log(ok ? 'KEEPALIVE CHECK: PASS (main thread waited correctly, no premature exit)' : 'KEEPALIVE CHECK: FAIL');
  process.exit(ok ? 0 : 1);
}

main();

// `Worker.run` (spec 059, wired for Node by spec 508 T009). The emitter
// never hands `Worker.run` a live closure -- it rewrites the call site
// into `{ moduleUrl, fnName, args }` (see `emitWorkerRun` in
// `lumen_emit_js_expr.zig` and spec 508's tasks.md T009) -- so this tests
// `lib/worker.mjs`'s side of that contract directly: given a descriptor,
// does it really run `fnName` from `moduleUrl` on a separate thread and
// resolve with its result, and does a thrown error there reject cleanly.
import { test } from "node:test";
import assert from "node:assert/strict";
import { Worker } from "../lib/worker.mjs";

const TARGET = new URL("./fixtures/worker_target.mjs", import.meta.url).href;

test("Worker.run resolves with the target function's return value", async () => {
  const result = await Worker.run({ moduleUrl: TARGET, fnName: "addSeven", args: [35] });
  assert.equal(result, 42);
});

test("Worker.run actually runs on a different thread, not inline", async () => {
  // node:worker_threads has no public "is this the main thread" check for
  // the callER, but a real Worker genuinely runs on a separate OS thread by
  // construction; what's testable and worth pinning is that the call does
  // not block the event loop -- a timer armed just before it must still
  // fire while the worker is running.
  let ticked = false;
  const timer = setTimeout(() => { ticked = true; }, 0);
  await Worker.run({ moduleUrl: TARGET, fnName: "addSeven", args: [1] });
  clearTimeout(timer);
  assert.equal(ticked, true);
});

test("a thrown error in the worker target rejects the promise with its message", async () => {
  await assert.rejects(
    Worker.run({ moduleUrl: TARGET, fnName: "throwsAlways", args: [] }),
    /deliberate failure from a worker target/,
  );
});

test("two concurrent Worker.run calls both resolve, with distinct correct values", async () => {
  const [a, b] = await Promise.all([
    Worker.run({ moduleUrl: TARGET, fnName: "addSeven", args: [10] }),
    Worker.run({ moduleUrl: TARGET, fnName: "addSeven", args: [20] }),
  ]);
  assert.equal(a, 17);
  assert.equal(b, 27);
});

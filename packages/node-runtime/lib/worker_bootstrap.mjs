// Runs inside the worker_threads thread `Worker.run` spawns (spec 059/508
// T009). `workerData` names the module the target function lives in (the
// same file the emitter's `Worker.run` call site sits in — plain top-level
// function or a synthesized one for a scalar-capturing arrow, spec 508
// spec.md's Worker.run design) and the argument values to call it with.
//
// This thread is a fresh Node module graph with nothing on `globalThis`
// yet, so `../globals.mjs` installs the Lumen namespaces here exactly as
// the program's own entry file does — a Worker.run target that itself
// calls `fs.*`/`crypto.*`/etc. needs them. Re-importing `moduleUrl` re-runs
// that module's own top-level statements in this thread: harmless for the
// ordinary case (declarations), and an explicit, documented consequence of
// module state not being shared across a Worker.run boundary (059's own
// restriction to scalar captures already assumes it isn't).
import { parentPort, workerData } from "node:worker_threads";
import "../globals.mjs";

const { moduleUrl, fnName, args } = workerData;
try {
  const mod = await import(moduleUrl);
  const fn = mod[fnName];
  const result = await fn(...args);
  parentPort.postMessage({ ok: true, result });
} catch (e) {
  parentPort.postMessage({ ok: false, message: e && e.message ? e.message : String(e) });
}

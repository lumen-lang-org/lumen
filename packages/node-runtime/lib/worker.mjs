// `Worker.run(fn)` (spec 059, wired for Node by spec 508 T009): a real
// OS thread returning a scalar through a promise. `fn` never reaches here
// as a live JS value -- a fresh worker_threads thread is a fresh module
// graph, and a closure over this one's bindings means nothing there. The
// emitter (`lumen_emit_js_expr.zig`'s `emitWorkerRun`) rewrites the call
// site into a descriptor instead: which module to `import()` in the new
// thread, which of its exports to call, and the (scalar-only, per 059) argument
// values to call it with. `worker_bootstrap.mjs` is what the spawned thread
// actually runs.
import { Worker as ThreadWorker } from "node:worker_threads";
import { fileURLToPath } from "node:url";

const bootstrapPath = fileURLToPath(new URL("./worker_bootstrap.mjs", import.meta.url));

export const Worker = {
  run({ moduleUrl, fnName, args }) {
    return new Promise((resolve, reject) => {
      const w = new ThreadWorker(bootstrapPath, { workerData: { moduleUrl, fnName, args } });
      w.once("message", (m) => {
        w.terminate();
        if (m.ok) resolve(m.result);
        else reject(new Error(m.message));
      });
      w.once("error", (e) => {
        w.terminate();
        reject(e);
      });
    });
  },
};

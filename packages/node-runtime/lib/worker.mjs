// `Worker.run(fn)` (spec 059): a real thread returning a scalar through a
// promise. On Node that is a `worker_threads` Worker per call, which needs
// the emitted module and the shared-state rules of spec 508.
export const Worker = {
  run() {
    throw new Error("Worker.run needs the worker bridge, spec 508");
  },
};

// A tiny module playing the part of a lumen --target node module that
// declares a Worker.run target, exactly as the real emitter's
// `emitWorkerRun` (lumen_emit_js_expr.zig) requires: an exported,
// zero-argument-shape-agnostic function returning a scalar.
export function addSeven(x) {
  return x + 7;
}

export function throwsAlways() {
  throw new Error("deliberate failure from a worker target");
}

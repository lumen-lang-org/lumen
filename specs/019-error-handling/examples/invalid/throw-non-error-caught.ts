// Only an Error or a string may be thrown (spec 249 accepts a bare string,
// deliberately -- "an Error carries a string message at runtime, so the
// lowering is identical"); anything else is rejected. Distinct from the
// sibling throw-number.ts: caught inside a try/catch, not thrown bare.
try {
  throw true;
} catch (e) {
  console.log(e.message);
}

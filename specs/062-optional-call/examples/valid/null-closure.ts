// cb?.() on a null closure: does not call through, the whole expression
// evaluates to null (coalesced here to `fallback`), no crash.
type Cb = () => int;

function callOrDefault(fallback: int, cb: Cb | null): int {
  const r = cb?.();
  return r ?? fallback;
}

console.log(callOrDefault(5, null));

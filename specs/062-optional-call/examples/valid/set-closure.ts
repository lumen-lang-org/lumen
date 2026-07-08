// cb?.() on a set (non-null) closure: calls through and returns the value.
type Cb = () => int;

function callOrDefault(fallback: int, cb: Cb | null): int {
  const r = cb?.();
  return r ?? fallback;
}

console.log(callOrDefault(5, () => 99));

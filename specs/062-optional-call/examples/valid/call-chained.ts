// getCb()?.() -- optional call chained off a preceding call's result.
type Cb = () => int;

function getCb(active: bool): Cb | null {
  if (active) {
    return () => 55;
  }
  return null;
}

console.log(getCb(true)?.() ?? -1);
console.log(getCb(false)?.() ?? -1);

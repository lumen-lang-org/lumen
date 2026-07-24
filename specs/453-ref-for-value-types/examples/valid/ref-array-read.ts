// length and indexing inside the callee see the caller's value.
function describe(xs: Ref<int[]>): int {
  return xs.length + xs[0];
}
let a: int[] = [5, 6, 7];
console.log(describe(a));

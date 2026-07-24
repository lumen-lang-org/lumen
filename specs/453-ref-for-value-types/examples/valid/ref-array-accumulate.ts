// R1: a callee accumulates into the caller's array.
function fill(out: Ref<int[]>): void {
  out = [...out, 1];
  out = [...out, 2];
}
let a: int[] = [];
fill(a);
console.log(a.length);

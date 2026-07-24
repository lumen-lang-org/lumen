// the regression guard for the model: without Ref an array parameter is a
// copy, so push stays local.
function localOnly(xs: int[]): void {
  xs.push(99);
}
let a: int[] = [1];
localOnly(a);
console.log(a.length);

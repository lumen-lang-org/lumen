// a Ref parameter passed on to another Ref parameter.
function inner(xs: Ref<int[]>): void {
  xs = [...xs, 3];
}
function outer(xs: Ref<int[]>): void {
  inner(xs);
  xs = [...xs, 4];
}
let a: int[] = [];
outer(a);
console.log(a.length);

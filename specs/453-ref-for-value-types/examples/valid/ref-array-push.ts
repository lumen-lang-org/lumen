// push through a Ref is the same rebinding as an assignment, so it reaches
// the caller too.
function add(out: Ref<int[]>): void {
  out.push(7);
}
let xs: int[] = [1];
add(xs);
console.log(xs.length);

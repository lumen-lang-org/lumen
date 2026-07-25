// A `Ref<T>` parameter that shadows a top-level name: the callee still writes
// through to the caller's binding.
function count(xs: int[]): int { return xs.length; }

function grow(count: Ref<int[]>): void {
  count.push(9);
  count.push(10);
}

function main(): void {
  let xs: int[] = [1];
  grow(xs);
  console.log(`${count(xs)} ${xs[2]}`);
}
main();

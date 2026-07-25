// A shadowing parameter the body also reassigns: one binding, not two — the
// mutable-copy path and the rename must compose.
function total(xs: int[]): int {
  let sum = 0;
  for (let i = 0; i < xs.length; i = i + 1) { sum = sum + xs[i]; }
  return sum;
}

function normalise(total: int): int {
  total = total + 1;
  if (total > 10) { total = 10; }
  return total;
}

function main(): void {
  console.log(`${normalise(total([1, 2, 3]))}`);
  console.log(`${normalise(total([20, 30]))}`);
}
main();

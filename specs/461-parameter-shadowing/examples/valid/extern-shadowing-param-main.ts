// An `extern function` is a top-level declaration too, and its own parameters
// live in the same namespace as everyone else's.
// @link c
declare function abs(v: int): int;

function scale(n: int): int { return n * 2; }

function apply(scale: int, abs: int): int {
  return scale + abs;
}

function main(): void {
  console.log(`${apply(scale(3), abs(0 - 4))}`);
}
main();

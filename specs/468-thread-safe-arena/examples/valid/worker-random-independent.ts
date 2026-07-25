// `Math.random` keeps a generator state, and a generator state belongs to the
// stream drawing from it. Each worker draws its own numbers: every draw is in
// range, and no thread's run collapses onto a constant, which is what a shared
// state raced by four threads can produce. The counts are what is printed --
// the numbers themselves are not reproducible and are not asserted.
function draw(rounds: int): int {
  let inRange: int = 0;
  let distinct: int = 0;
  let prev: number = -1;
  let i: int = 0;
  while (i < rounds) {
    const r = Math.random();
    if (r >= 0 && r < 1) { inRange = inRange + 1; }
    if (r != prev) { distinct = distinct + 1; }
    prev = r;
    i = i + 1;
  }
  if (distinct < rounds / 2) { return -1; }
  return inRange;
}

function jobA(): int { return draw(5000); }
function jobB(): int { return draw(5000); }
function jobC(): int { return draw(5000); }

async function main(): Promise<void> {
  const a = Worker.run(jobA);
  const b = Worker.run(jobB);
  const c = Worker.run(jobC);
  console.log(await a);
  console.log(await b);
  console.log(await c);
  console.log(draw(5000));
}
main();

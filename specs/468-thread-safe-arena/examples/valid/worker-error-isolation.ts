// Four threads, each throwing and catching its own error twenty thousand
// times. Every catch must see the message its own thread threw, so every count
// comes back as the full round count. Before spec 468 the thrown message lived
// in one process-global and the counts came back short by a few hundred.
function boom(tag: string): int { throw new Error("boom:" + tag); }

function countOwn(tag: string, rounds: int): int {
  let own: int = 0;
  let i: int = 0;
  while (i < rounds) {
    let v: int = 0;
    try { v = boom(tag); own = own + v; } catch (e) { if (e.message == "boom:" + tag) { own = own + 1; } }
    i = i + 1;
  }
  return own;
}

function jobA(): int { return countOwn("alpha", 20000); }
function jobB(): int { return countOwn("bravo", 20000); }
function jobC(): int { return countOwn("charlie", 20000); }
function jobD(): int { return countOwn("delta", 20000); }

async function main(): Promise<void> {
  const a = Worker.run(jobA);
  const b = Worker.run(jobB);
  const c = Worker.run(jobC);
  const d = Worker.run(jobD);
  console.log(await a);
  console.log(await b);
  console.log(await c);
  console.log(await d);
}
main();

// The same isolation, but with sixteen frames to unwind through each time, on
// three worker threads plus the main one. This is the case that reached past
// the end of the trace buffer before spec 468: four threads pushing frames
// onto one 128-entry array walked the shared depth counter to 131, and the
// same counter underflowed on the way back down.
function deep(n: int, tag: string): int {
  if (n == 0) { throw new Error("bottom:" + tag); }
  return deep(n - 1, tag) + 1;
}

function unwind(tag: string, rounds: int): int {
  let ok: int = 0;
  let i: int = 0;
  while (i < rounds) {
    let v: int = 0;
    try { v = deep(16, tag); ok = ok + v; } catch (e) { if (e.message == "bottom:" + tag) { ok = ok + 1; } }
    i = i + 1;
  }
  return ok;
}

function jobA(): int { return unwind("a", 8000); }
function jobB(): int { return unwind("b", 8000); }
function jobC(): int { return unwind("c", 8000); }

async function main(): Promise<void> {
  const a = Worker.run(jobA);
  const b = Worker.run(jobB);
  const c = Worker.run(jobC);
  console.log(await a);
  console.log(await b);
  console.log(await c);
  console.log(unwind("main", 8000));
}
main();

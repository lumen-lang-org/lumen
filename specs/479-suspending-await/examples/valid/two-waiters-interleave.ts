// Two waiters, started before either is awaited.
//
// With suspension the shorter deadline finishes first, whichever is awaited
// first. Today both bodies run to completion at their call sites, so this
// prints the call order and the "both started" line arrives last.
async function waitFor(name: string, ms: int): Promise<string> {
  await pause(ms);
  console.log("finished " + name);
  return name;
}

async function pause(ms: int): Promise<int> {
  setTimeout(() => { }, ms);
  let done = Promise.resolve(ms);
  return await done;
}

async function main(): Promise<void> {
  let slow = waitFor("slow", 300);
  let quick = waitFor("quick", 50);
  console.log("both started");
  let a = await slow;
  let b = await quick;
  console.log("awaited " + a + " then " + b);
}
main();

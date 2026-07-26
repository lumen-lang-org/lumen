// process.sleep pauses the thread; zero and negative are no-ops.
function main(): void {
  let before = Date.now();
  process.sleep(120);
  let after = Date.now();
  if (after - before >= 120) { console.log("slept"); } else { console.log("too short"); }

  process.sleep(0);
  process.sleep(-5);
  console.log("no-op");

  // Still a plain () => void, so a loop can pace itself without the event loop.
  let ticks: int = 0;
  while (ticks < 3) { process.sleep(1); ticks = ticks + 1; }
  console.log(`${ticks}`);
}
main();

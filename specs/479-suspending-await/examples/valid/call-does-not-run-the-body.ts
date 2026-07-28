// Calling an async function starts a task. It does not run the body.
async function work(): Promise<int> {
  console.log("inside the body");
  return 1;
}

async function main(): Promise<void> {
  let running = work();
  console.log("after the call");
  let n = await running;
  console.log("awaited " + `${n}`);
}
main();

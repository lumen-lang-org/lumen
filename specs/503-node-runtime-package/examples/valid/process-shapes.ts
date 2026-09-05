// process.* as calls, argv/argsCount/arg, env(k) as string | null,
// stdout()/stderr() streams, child_process.spawnSync, sleep.
console.log(process.platform().length > 0, process.arch().length > 0, process.pid() > 0);
console.log(process.env("LUMEN_503_ABSENT") == null, process.env("PATH") != null);
console.log(argsCount() == process.argv().length, arg(99) == "", process.cwd().length > 0);
process.stdout().write("via stdout\n");
process.stderr().write("via stderr\n");
let r = child_process.spawnSync("sh", ["-c", "printf out; printf err >&2; exit 3"]);
console.log(r.stdout, r.stderr, r.status);
let gone = child_process.spawnSync("/no/such/binary", []);
console.log(gone.stdout == "", gone.status);
let before: i64 = time.monotonic();
process.sleep(20);
console.log(time.monotonic() - before >= 15);
let em = new EventEmitter<int>();
function onAdd(v: int): void {
  console.log("add", v);
}
em.on("add", onAdd);
em.once("add", onAdd);
em.emit("add", 1);
em.emit("add", 2);
console.log(em.listenerCount("add"));
console.log(Math.clamp(9, 0, 5), String.contains("hello", "ell"), String.isEmpty(""), Array.isEmpty([1]));
console.log(Number.parseInt("42") == 42, Number.parseInt("x") == null, Number.parseFloat("2.5") == 2.5);
assert.ok(true);
assert.equal("a", "a");
console.log("done");

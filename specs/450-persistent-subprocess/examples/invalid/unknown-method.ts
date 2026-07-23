// ChildProcess exposes only write/writeLine/readLine/close (spec 450).
let empty: string[] = [];
let cp = child_process.spawn("cat", empty);
cp.frobnicate();

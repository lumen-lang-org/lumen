// ChildProcess.readLine() takes no arguments (spec 450).
let empty: string[] = [];
let cp = child_process.spawn("cat", empty);
let line = cp.readLine("extra");
cp.close();

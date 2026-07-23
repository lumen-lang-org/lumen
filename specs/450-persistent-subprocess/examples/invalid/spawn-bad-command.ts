// child_process.spawn's first argument must be a string command (spec 450).
let args: string[] = ["x"];
let cp = child_process.spawn(42, args);
cp.close();

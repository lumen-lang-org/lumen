// SC-002: a readLine() loop over spawn("cat") round-trips many lines
// without drift. 10k lines, matching this spec's own success criterion --
// large enough that a broker call sized wrong (spec 508 T002's fixed
// binary encoding) or a readLine that drops/duplicates a line under load
// would show up as a mismatch rather than passing by accident.
const N: int = 10000;
let empty: string[] = [];
let cp = child_process.spawn("cat", empty);
let i: int = 0;
while (i < N) {
  cp.writeLine(`line${i}`);
  i = i + 1;
}
let ok: bool = true;
let mismatchAt: int = -1;
i = 0;
while (i < N) {
  let line = cp.readLine();
  if (line != `line${i}\n`) {
    ok = false;
    mismatchAt = i;
    break;
  }
  i = i + 1;
}
cp.close();
console.log(ok ? "ok" : `mismatch at ${mismatchAt}`);

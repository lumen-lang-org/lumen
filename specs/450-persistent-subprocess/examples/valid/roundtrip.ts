// Persistent piped subprocess round trips (spec 450). `cat` echoes each line of
// its stdin straight to its stdout, so it is the standard line-oriented tool for
// exercising a long-lived stdin/stdout conversation. readLine() keeps the
// trailing newline (see spec.md's "Line reading"), so an echoed "hello" reads
// back as "hello\n".

test("single round trip echoes the written line", () => {
  let empty: string[] = [];
  let cp = child_process.spawn("cat", empty);
  cp.writeLine("hello");
  let line = cp.readLine();
  expect(line == "hello\n");
  cp.close();
});

test("two round trips share one long-lived child", () => {
  let empty: string[] = [];
  let cp = child_process.spawn("cat", empty);
  cp.writeLine("one");
  expect(cp.readLine() == "one\n");
  cp.writeLine("two");
  expect(cp.readLine() == "two\n");
  cp.close();
});

test("readLine returns empty string at EOF", () => {
  // `echo done` writes "done\n" and exits, closing its stdout. The first
  // readLine sees the line; the second sees end-of-stream and returns "".
  let args: string[] = ["done"];
  let cp = child_process.spawn("echo", args);
  expect(cp.readLine() == "done\n");
  expect(cp.readLine() == "");
  cp.close();
});

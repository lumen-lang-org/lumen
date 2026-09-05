import { test } from "node:test";
import assert from "node:assert/strict";
import { process as P, argsCount, arg, installProcess } from "../lib/process.mjs";
import { ReadableStream, WritableStream } from "../lib/streams.mjs";
import { runProgram } from "./helpers.mjs";

test("platform/arch/pid/version are calls (specs 033, 050)", () => {
  assert.ok(["linux", "darwin", "win32", "freebsd", "openbsd", "unknown"].includes(P.platform()));
  assert.ok(["x64", "ia32", "arm64", "arm", "riscv64", "unknown"].includes(P.arch()));
  assert.equal(P.pid(), process.pid);
  assert.equal(P.version(), "0.3.1");
});

test("env(k) is the value or null; never undefined", () => {
  assert.equal(typeof P.env("PATH"), "string");
  assert.equal(P.env("LUMEN_NO_SUCH_VARIABLE_503"), null);
});

test("argv()/argsCount()/arg(i): the program is argv[0]; past the end is \"\"", () => {
  const argv = P.argv();
  assert.equal(argv.length, process.argv.length - 1);
  assert.equal(argsCount(), argv.length);
  assert.equal(arg(0), argv[0]);
  assert.equal(arg(9999), "");
});

test("sleep(ms) blocks the thread (spec 475)", () => {
  const t0 = Date.now();
  P.sleep(30);
  assert.ok(Date.now() - t0 >= 25);
  P.sleep(0);
  P.sleep(-5);
});

test("kill: false for a process that is not there, an unknown signal probes (signal 0)", () => {
  assert.equal(P.kill(2 ** 22 - 1, "TERM"), false);
  assert.equal(P.kill(process.pid, "NOSUCHSIGNAL"), true);
  assert.equal(P.kill(process.pid, "SIGCONT"), true);
});

test("umask/setUmask, ids, uptime, hrtime, memoryUsage have native shapes", () => {
  const old = P.umask();
  assert.equal(typeof old, "number");
  assert.equal(P.setUmask(old), old);
  for (const f of ["getuid", "getgid", "geteuid", "getegid"]) assert.equal(typeof P[f](), "number");
  assert.ok(P.uptime() >= 0);
  assert.ok(P.hrtime() > 0 && Number.isInteger(P.hrtime()));
  const m = P.memoryUsage();
  assert.deepEqual(Object.keys(m).sort(), ["rss", "vsize"]);
  if (process.platform === "linux") assert.ok(m.rss > 0);
});

test("cwd/chdir round-trip; chdir to a missing directory is silent", () => {
  const here = P.cwd();
  assert.equal(here, process.cwd());
  P.chdir("/definitely/not/a/directory");
  assert.equal(P.cwd(), here);
});

test("stdin()/stdout()/stderr() are the stream shapes of spec 053, one instance each", () => {
  assert.ok(P.stdin() instanceof ReadableStream);
  assert.ok(P.stdout() instanceof WritableStream);
  assert.ok(P.stderr() instanceof WritableStream);
  assert.equal(P.stdout(), P.stdout());
});

test("installProcess grafts the calls onto a process-like object without breaking property access", () => {
  const target = { platform: process.platform, env: process.env, stdout: process.stdout };
  installProcess(target);
  assert.equal(target.platform(), P.platform());
  assert.ok(target.platform == process.platform);
  assert.equal(`${target.platform}`, process.platform);
  assert.equal(target.env("PATH"), process.env.PATH);
  assert.equal(target.env.PATH, process.env.PATH);
  assert.equal(typeof target.stdout.write, "function");
  assert.ok(target.stdout() instanceof WritableStream);
  assert.equal(target.pid(), process.pid);
  assert.equal(typeof target.sleep, "function");
  installProcess(target);
});

test("stdout().write and stderr().write reach the real descriptors, interleaved with console.log", () => {
  const r = runProgram('console.log("a"); process.stdout().write("b\\n"); process.stderr().write("e\\n"); console.log("c");');
  assert.equal(r.status, 0);
  assert.equal(r.stdout, "a\nb\nc\n");
  assert.equal(r.stderr, "e\n");
});

test("stdin().readLine keeps the terminator, blank lines are \"\\n\", EOF is \"\" (spec 053)", () => {
  const r = runProgram('const s = process.stdin(); let l = s.readLine(); while (l !== "") { process.stdout().write("[" + l + "]"); l = s.readLine(); } console.log("|end");', { input: "x\n\ny" });
  assert.equal(r.stdout, "[x\n][\n][y]|end\n");
});

test("exit(code) ends the program with that status", () => {
  const r = runProgram('console.log("before"); process.exit(3); console.log("after");');
  assert.equal(r.status, 3);
  assert.equal(r.stdout, "before\n");
});

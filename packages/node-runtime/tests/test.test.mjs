import { test } from "node:test";
import assert from "node:assert/strict";
import { runProgram } from "./helpers.mjs";
import { fileURLToPath } from "node:url";

const REPORTER = fileURLToPath(new URL("../lib/test_reporter.mjs", import.meta.url));
const LUMEN_FLAGS = ["--test", `--test-reporter=${REPORTER}`, "--test-reporter-destination=stderr"];

/** The reporter writes text; `runProgram` reads bytes. */
function utf8(latin1) { return Buffer.from(latin1, "latin1").toString("utf8"); }

const PROGRAM = `
test("adds", () => { expect(1 + 1).toBe(2); expect(true); expect(false).toBe(false); expect([1, 2]).toEqual([1, 2]); });
test("boolean form fails", () => { expect(1 > 2); console.log("still runs to the end of the body"); });
test("matcher fails", () => { expect("a").toBe("b"); });
test("throw fails only this test", () => { throw new Error("boom"); });
console.log("module body ran");
`;

test("under plain node the test blocks do not run, like `lumen run` (spec 008)", () => {
  const r = runProgram(PROGRAM);
  assert.equal(r.status, 0);
  assert.equal(r.stdout, "module body ran\n");
});

test("under node --test each block is a node:test test; expect maps to node:assert (spec 506)", () => {
  const r = runProgram(PROGRAM, { flags: ["--test"] });
  assert.equal(r.status, 1);
  assert.match(r.stdout, /ok 1 - adds/);
  assert.match(r.stdout, /not ok 2 - boolean form fails/);
  assert.match(r.stdout, /expect\(false\)/);
  assert.match(r.stdout, /not ok 3 - matcher fails/);
  assert.match(r.stdout, /expected "b", found "a"/);
  assert.match(r.stdout, /not ok 4 - throw fails only this test/);
  assert.match(r.stdout, /boom/);
  assert.match(r.stdout, /# pass 1\n/);
  assert.match(r.stdout, /# fail 3\n/);
});

test("LUMEN_TEST=inline runs each block at declaration and tallies in globalThis.__t", () => {
  const r = runProgram(PROGRAM + 'setTimeout(() => console.log(JSON.stringify(globalThis.__t)), 10);', { env: { LUMEN_TEST: "inline" } });
  assert.equal(r.status, 0);
  const tally = JSON.parse(r.stdout.trim().split("\n").pop());
  assert.equal(tally.pass, 1);
  assert.equal(tally.fail, 3);
  assert.deepEqual(tally.failures.map((f) => f.split(":")[0]), ["boolean form fails", "matcher fails", "throw fails only this test"]);
});

test("the lumen reporter prints the native runner's lines on stderr and passes the program's stdout through (spec 506)", () => {
  const r = runProgram(PROGRAM, { flags: LUMEN_FLAGS, env: { NO_COLOR: "1" } });
  assert.equal(r.status, 1);
  assert.equal(r.stdout, "module body ran\nstill runs to the end of the body\n");
  const lines = utf8(r.stderr).split("\n");
  assert.equal(lines[0], "ok adds");
  assert.equal(lines[1], "FAIL boolean form fails — expect(false)");
  assert.match(lines[2], /^    at .*prog\.ts:3$/);
  assert.equal(lines[3], 'FAIL matcher fails — expected "b", found "a"');
  assert.match(lines[4], /^    at .*prog\.ts:4$/);
  assert.equal(lines[5], "FAIL throw fails only this test — Uncaught Error: boom");
  assert.match(lines[6], /^    at .*prog\.ts:5$/);
  assert.equal(lines[7], "1 passed, 3 failed");
});

test("the lumen reporter names a file with no tests and a program that failed to load (spec 242)", () => {
  const none = runProgram('console.log("only a program");\n', { flags: LUMEN_FLAGS, env: { NO_COLOR: "1", LUMEN_TEST_SOURCE: "only.ts" } });
  assert.equal(none.status, 0);
  assert.equal(none.stdout, "only a program\n");
  assert.equal(none.stderr, "only.ts: no tests\n");
  const bad = runProgram('throw new Error("at load");\n', { flags: LUMEN_FLAGS, env: { NO_COLOR: "1", LUMEN_TEST_SOURCE: "bad.ts" } });
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /at load/);
  assert.match(utf8(bad.stderr), /^FAIL bad\.ts — the program did not load\n0 passed, 0 failed\n$/m);
});

test("a matcher failure shows both values the way the program would print them", () => {
  const r = runProgram('test("bytes", () => { expect("h\\xC3\\xA9").toBe("he"); });\ntest("floats", () => { expect(0.1 + 0.2).toBe(0.3); });\ntest("lists", () => { expect([1, 2]).toEqual([1]); });\n', { flags: LUMEN_FLAGS, env: { NO_COLOR: "1" } });
  assert.equal(r.status, 1);
  const out = utf8(r.stderr);
  assert.match(out, /FAIL bytes — expected "he", found "hé"/);
  assert.match(out, /FAIL floats — expected 0.3, found 0.30000000000000004/);
  assert.match(out, /FAIL lists — expected \[ 1 \], found \[ 1, 2 \]/);
});

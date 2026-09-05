import { test } from "node:test";
import assert from "node:assert/strict";
import { runProgram } from "./helpers.mjs";

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
  assert.match(r.stdout, /Expected values to be strictly equal/);
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

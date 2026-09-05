import { test } from "node:test";
import assert from "node:assert/strict";
import * as A from "../lib/assert.mjs";
import { runProgram } from "./helpers.mjs";

test("a passing assertion is silent", () => {
  A.ok(true);
  A.equal(1, 1);
  A.equal("a", "a");
});

test("a failing assertion ends the program, uncatchably, like the native panic", () => {
  const r = runProgram('try { assert.ok(1 > 2); } catch (e) { console.log("caught"); } console.log("after");');
  assert.notEqual(r.status, 0);
  assert.equal(r.stdout, "");
  assert.match(r.stderr, /AssertionError: assert\.ok failed/);
  const s = runProgram('assert.equal("a", "b");');
  assert.match(s.stderr, /AssertionError: "a" != "b"/);
  const n = runProgram("assert.equal(1, 2);");
  assert.match(n.stderr, /AssertionError: 1 != 2/);
});

import { test } from "node:test";
import assert from "node:assert/strict";
import * as cp from "../lib/child_process.mjs";

test("spawnSync returns strings and the exit status (spec 037)", () => {
  assert.deepEqual(cp.spawnSync("sh", ["-c", "printf out; printf err >&2; exit 3"]), { stdout: "out", stderr: "err", status: 3 });
  assert.equal(cp.spawnSync("printf", ["\\303\\251"]).stdout, "\xc3\xa9");
});

test("a command that cannot start or dies by a signal is status -1 with \"\" output", () => {
  assert.deepEqual(cp.spawnSync("/no/such/binary", []), { stdout: "", stderr: "", status: -1 });
  assert.equal(cp.spawnSync("sh", ["-c", "kill -KILL $$"]).status, -1);
});

test("stdin is not connected: a reader sees end of input at once", () => {
  assert.equal(cp.spawnSync("cat", []).stdout, "");
});

test("spawn is deferred to spec 508 by name", () => {
  assert.throws(() => cp.spawn("cat", []), /child_process\.spawn needs the I\/O broker, spec 508/);
});

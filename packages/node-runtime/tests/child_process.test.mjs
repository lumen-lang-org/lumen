import { test, after } from "node:test";
import assert from "node:assert/strict";
import * as cp from "../lib/child_process.mjs";
import { shutdownBridge } from "../lib/broker/sync_bridge.mjs";

after(() => shutdownBridge());

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

test("spawn/writeLine/readLine round-trips lines through a real \"cat\", close waits for exit (spec 450, wired to the spec 508 broker)", () => {
  const child = cp.spawn("cat", []);
  child.writeLine("one");
  assert.equal(child.readLine(), "one\n");
  child.writeLine("two");
  assert.equal(child.readLine(), "two\n");
  child.close(); // closes stdin, cat sees EOF and exits; close() blocks for it
});

test("readLine drains a many-line round trip through \"cat\" without drift (a smaller version of spec 508 T011's SC-002 10k-line conformance case, kept fast here)", () => {
  const child = cp.spawn("cat", []);
  const N = 2000;
  for (let i = 0; i < N; i++) child.writeLine("line" + i);
  for (let i = 0; i < N; i++) assert.equal(child.readLine(), "line" + i + "\n");
  child.close();
});

test("write() sends raw bytes with no added newline; readLine reassembles across writes", () => {
  const child = cp.spawn("cat", []);
  child.write("partial-");
  child.write("line\n");
  assert.equal(child.readLine(), "partial-line\n");
  child.close();
});

test("a command that cannot start degrades to a dead handle: readLine/write/close never throw (LumenChildProcess's null-child fallback)", () => {
  const child = cp.spawn("/no/such/binary", []);
  assert.equal(child.readLine(), "");
  assert.doesNotThrow(() => child.write("x"));
  assert.doesNotThrow(() => child.writeLine("x"));
  assert.doesNotThrow(() => child.close());
});

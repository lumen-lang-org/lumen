// The two calls spec 508 refuses permanently (no per-connection handler
// model that shares module state, per its Decision) plus `Worker.run`
// (spec 508 T009 is not done): a program that reaches any of these fails
// loudly and by name. Everything else `net`/`http`/`child_process` accepts
// is wired to the I/O broker -- see net.test.mjs, http.test.mjs,
// child_process.test.mjs. The constant tables of `http` are real.
import { test } from "node:test";
import assert from "node:assert/strict";
import nhttp from "node:http";
import * as net from "../lib/net.mjs";
import * as http from "../lib/http.mjs";
import { Worker } from "../lib/worker.mjs";

test("net.createServer/http.createServer (permanently, spec 508's Decision) and Worker.run (spec 508 T009, not done) name spec 508", () => {
  assert.throws(() => net.createServer(0, () => {}), /net\.createServer is not supported on the node target \(spec 508/);
  assert.throws(() => http.createServer(0, () => {}), /http\.createServer is not supported on the node target \(spec 508/);
  assert.throws(() => Worker.run(() => 1), /Worker\.run needs the worker bridge, spec 508/);
});

test("http.METHODS() and STATUS_CODES() are the native runtime's tables (spec 049)", () => {
  const m = http.METHODS();
  assert.equal(m.length, 35);
  assert.equal(m[0], "ACL");
  assert.equal(m[34], "UNSUBSCRIBE");
  assert.ok(m.includes("QUERY"));
  assert.notEqual(http.METHODS(), m);
  const codes = http.STATUS_CODES();
  assert.ok(codes instanceof Map);
  assert.equal(codes.get(200), "OK");
  assert.equal(codes.get(404), "Not Found");
  assert.equal(codes.size, Object.keys(nhttp.STATUS_CODES).length);
});

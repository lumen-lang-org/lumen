// `http.createServer` is the one call still refused by name (spec 511
// tasks.md T012, a documented follow-up -- 511 gave `net.createServer`
// real async-handler support, see net.test.mjs for its own tests).
// Everything else `net`/`http`/`child_process` accepts is wired to the I/O
// broker -- see net.test.mjs, http.test.mjs, child_process.test.mjs;
// `Worker.run` (T009) has its own worker.test.mjs. The constant tables of
// `http` are real.
import { test } from "node:test";
import assert from "node:assert/strict";
import nhttp from "node:http";
import * as http from "../lib/http.mjs";

test("http.createServer still names itself unsupported (spec 511 tasks.md T012)", () => {
  assert.throws(() => http.createServer(0, () => {}), /http\.createServer is not supported on the node target yet \(spec 511/);
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

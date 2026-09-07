// Nothing `net`/`http`/`child_process` accepts is refused by name on the
// node target any more (spec 511 T012 was the last one, `http.createServer`
// -- see `http.test.mjs`'s own createServer tests, and `net.test.mjs` for
// `net.createServer`'s). `Worker.run` (T009) has its own worker.test.mjs.
// What's left here: the constant tables of `http`, which are real.
import { test } from "node:test";
import assert from "node:assert/strict";
import nhttp from "node:http";
import * as http from "../lib/http.mjs";

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

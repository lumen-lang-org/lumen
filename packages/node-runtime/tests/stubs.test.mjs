// The blocking set (spec 508): a program that reaches it fails loudly and by
// name. The constant tables of `http` are real.
import { test } from "node:test";
import assert from "node:assert/strict";
import nhttp from "node:http";
import * as net from "../lib/net.mjs";
import * as http from "../lib/http.mjs";
import { Worker } from "../lib/worker.mjs";

test("net.connect/createServer, http.request/get/stream/createServer, Worker.run name spec 508", () => {
  assert.throws(() => net.connect("127.0.0.1", 80), /net\.connect needs the I\/O broker, spec 508/);
  assert.throws(() => net.createServer(0, () => {}), /net\.createServer needs the I\/O broker, spec 508/);
  assert.throws(() => http.request("http://x", "GET", "", new Map()), /http\.request needs the I\/O broker, spec 508/);
  assert.throws(() => http.get("http://x"), /http\.get needs the I\/O broker, spec 508/);
  assert.throws(() => http.stream("http://x", "GET", "", new Map()), /http\.stream needs the I\/O broker, spec 508/);
  assert.throws(() => http.createServer(0, () => {}), /http\.createServer needs the I\/O broker, spec 508/);
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

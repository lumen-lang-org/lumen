// Spec 503 FR-001 / SC-001: every name the checker accepts exists in the
// package. `names.json` is generated from the checker by
// `tools/stdlib_names.py`; regenerate it when the checker learns a name.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as L from "../index.mjs";

const names = JSON.parse(readFileSync(new URL("./names.json", import.meta.url), "utf8"));

const NAMESPACES = {
  fs: L.fs, path: L.path, process: L.process, os: L.os, readline: L.readline,
  child_process: L.child_process, crypto: L.crypto, zlib: L.zlib, url: L.url,
  assert: L.assert, time: L.time, http: L.http, net: L.net, Buffer: L.Buffer, Worker: L.Worker,
  Math: L.builtins.Math, String: L.builtins.String, Array: L.builtins.Array, Number: L.builtins.Number,
  JSON: L.builtins.JSON, Date: L.builtins.Date, Promise: L.builtins.Promise,
};

for (const [ns, list] of Object.entries(names.namespaces)) {
  test(`namespace ${ns}: every checker-accepted name is exported`, () => {
    const target = NAMESPACES[ns];
    assert.ok(target, `the package has no module for namespace ${ns}`);
    const missing = list.filter((n) => typeof target[n] !== "function");
    assert.deepEqual(missing, [], `${ns} is missing: ${missing.join(", ")}`);
  });
}

test("every namespace in names.json is covered by this test", () => {
  const unknown = Object.keys(names.namespaces).filter((ns) => !(ns in NAMESPACES));
  assert.deepEqual(unknown, []);
});

test("globals: argsCount, arg, defer, test, expect", () => {
  const globals = { argsCount: L.argsCount, arg: L.arg, defer: L.defer, test: L.test, expect: L.expect };
  const missing = names.globals.filter((n) => typeof globals[n] !== "function");
  assert.deepEqual(missing, []);
});

// Receivers a program can construct today; each method the checker accepts
// on them must be a function on the instance.
function constructible() {
  const dir = mkdtempSync(join(tmpdir(), "lumen-names-"));
  const file = join(dir, "f.txt");
  writeFileSync(file, "x\n");
  const key = L.Buffer.from("k");
  const receivers = {
    Buffer: L.Buffer.from("abc"),
    EventEmitter: new L.EventEmitter(),
    Hash: L.crypto.createHash("sha256"),
    Hmac: L.crypto.createHmac("sha256", key),
    ReadableStream: L.fs.createReadStream(file),
    WritableStream: L.fs.createWriteStream(join(dir, "w.txt")),
    // Wired to the spec 508 broker now (T005-T007): a dead handle (nothing
    // is listening/spawned) still has every method as a real function,
    // which is all this test checks -- net.test.mjs/http.test.mjs/
    // child_process.test.mjs cover the actual blocking behavior.
    Socket: L.net.connect("127.0.0.1", 1),
    ChildProcess: L.child_process.spawn("/no/such/binary", []),
    HttpStream: L.http.stream("http://127.0.0.1:1/", "GET", "", new Map()),
  };
  const cleanup = () => {
    receivers.ReadableStream.close();
    receivers.WritableStream.close();
    rmSync(dir, { recursive: true, force: true });
  };
  return { receivers, cleanup };
}

// `ResponseWriter` (the SYNC streaming-handler parameter) is native-only:
// spec 511 T012 gave `http.createServer` real node-target support, but
// only its two `async` forms (buffered and, for streaming, a distinct
// `AsyncResponseWriter` -- see `http.test.mjs`'s own createServer tests);
// a sync handler stays refused on the node target (spec 452/511), so there
// is no way to construct a plain `ResponseWriter` here, and none should
// be -- this loop only reflects classes the node runtime can actually
// produce. `AsyncSocket`/`AsyncResponseWriter` are deliberately excluded
// from `names.json` entirely for the same reason `AsyncSocket` always has
// been (`tools/stdlib_names.py`'s mapping never listed
// `asyncSocketMethod`/`asyncResponseWriterMethod`): neither is ever
// constructed by calling something directly, only handed to a handler
// `net.createServer`/`http.createServer` itself invokes.
const NATIVE_ONLY_RECEIVERS = new Set(["ResponseWriter"]);

for (const [recv, list] of Object.entries(names.methods)) {
  if (NATIVE_ONLY_RECEIVERS.has(recv)) continue;
  test(`methods of ${recv}`, () => {
    const { receivers, cleanup } = constructible();
    try {
      const target = receivers[recv];
      assert.ok(target, `no way to construct a ${recv} in this test`);
      const missing = list.filter((n) => typeof target[n] !== "function");
      assert.deepEqual(missing, [], `${recv} is missing: ${missing.join(", ")}`);
    } finally {
      cleanup();
    }
  });
}

test("methods of ResponseWriter: native-only, not reflected here", () => {
  for (const recv of NATIVE_ONLY_RECEIVERS) assert.ok(recv in names.methods, `${recv} unexpectedly missing from names.json`);
});

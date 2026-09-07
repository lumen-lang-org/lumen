// `http.request`/`get`/`stream` (specs 042, 452), wired to the spec 508 I/O
// broker. `request`/`get` never throw, even on a failed request
// (src/lumen_runtime_net.zig's `__httpRequest` fetch-failure fallback);
// `stream` mirrors `LumenHttpStream`'s status()/header()/readLine()/done()/
// close(), plus its own "any open failure degrades to a dead handle"
// convention.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import * as http from "../lib/http.mjs";
import { shutdownBridge } from "../lib/broker/sync_bridge.mjs";

after(() => shutdownBridge());

const PEER = fileURLToPath(new URL("./fixtures/http_peer.mjs", import.meta.url));

function startPeer() {
  const child = spawn(process.execPath, [PEER]);
  return new Promise((resolve, reject) => {
    let buf = "";
    child.stdout.on("data", (d) => {
      buf += d.toString();
      const m = buf.match(/PORT (\d+)/);
      if (m) resolve({ child, port: Number(m[1]) });
    });
    child.on("error", reject);
  });
}

test("request() sends method/headers/body and reads the full response", async () => {
  const { child, port } = await startPeer();
  try {
    const headers = new Map([["x-tag", "hello"]]);
    const r = http.request(`http://127.0.0.1:${port}/echo`, "POST", "world", headers);
    assert.equal(r.status, 200);
    assert.equal(r.ok, true);
    assert.equal(r.body, "POST /echo hello world");
    // Response headers are deliberately not surfaced, on either target.
    assert.equal(r.headers.size, 0);
  } finally {
    child.kill();
  }
});

test("get() is request(url, \"GET\", \"\", {})", async () => {
  const { child, port } = await startPeer();
  try {
    const r = http.get(`http://127.0.0.1:${port}/echo`);
    assert.equal(r.body, "GET /echo  ");
  } finally {
    child.kill();
  }
});

test("a non-2xx status is ok: false, still with its body", async () => {
  const { child, port } = await startPeer();
  try {
    const r = http.get(`http://127.0.0.1:${port}/status/404`);
    assert.equal(r.status, 404);
    assert.equal(r.ok, false);
  } finally {
    child.kill();
  }
});

test("request() never throws on a connection failure: it degrades to status -1", () => {
  const r = http.request("http://127.0.0.1:1/echo", "GET", "", new Map());
  assert.equal(r.status, -1);
  assert.equal(r.ok, false);
  assert.equal(r.body, "");
});

test("stream() reads the response line by line as it arrives, then done()", async () => {
  const { child, port } = await startPeer();
  try {
    const s = http.stream(`http://127.0.0.1:${port}/lines`, "GET", "", new Map());
    assert.equal(s.status(), 200);
    assert.equal(s.header("content-type"), "text/event-stream");
    assert.equal(s.header("Content-Type"), "text/event-stream"); // case-insensitive
    assert.equal(s.header("no-such-header"), "");
    assert.equal(s.done(), false);
    assert.equal(s.readLine(), "data: 1\n");
    assert.equal(s.readLine(), "data: 2\n");
    assert.equal(s.readLine(), "data: 3\n");
    assert.equal(s.readLine(), "");
    assert.equal(s.done(), true);
    s.close();
  } finally {
    child.kill();
  }
});

test("a failed stream open never throws: it degrades to a dead handle (status -1, done() true, empty reads)", () => {
  const s = http.stream("http://127.0.0.1:1/echo", "GET", "", new Map());
  assert.equal(s.status(), -1);
  assert.equal(s.done(), true);
  assert.equal(s.readLine(), "");
  assert.equal(s.read(), "");
  assert.doesNotThrow(() => s.write("x"));
  assert.doesNotThrow(() => s.close());
});

test("http.createServer is refused at run time (also refused at compile time, permanently)", () => {
  assert.throws(() => http.createServer(), /http\.createServer is not supported on the node target/);
});

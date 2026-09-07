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
import nhttp from "node:http";
import nnet from "node:net";
import * as http from "../lib/http.mjs";
import { shutdownBridge } from "../lib/broker/sync_bridge.mjs";

after(() => shutdownBridge());

// `http.createServer` (spec 511 T012) runs directly on the calling thread
// (unlike `net.createServer`, whose listener lives on the broker worker
// thread and goes away with `shutdownBridge()` above) -- every server a
// test below starts is collected here and closed in one `after()`, or it
// would keep this file's own process alive past every test completing.
const servers = [];
after(() => Promise.all(servers.map((s) => new Promise((r) => s.close(r)))));

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

/** A real client request against `http.createServer`'s own port, via
 *  Node's own `http` client (unlike `http_peer.mjs`'s raw fixture, above,
 *  which exists to answer a client -- this is a client answering
 *  `lib/http.mjs`'s own server). */
function clientRequest(port, path, { method = "GET", body = "" } = {}) {
  return new Promise((resolve, reject) => {
    const req = nhttp.request({ port, path, method }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString() }));
    });
    req.on("error", reject);
    req.end(body);
  });
}

test("http.createServer: a buffered async handler answers a real client", async () => {
  servers.push(http.createServer(19620, async (req) => ({
    status: 200,
    body: `${req.method} ${req.path}`,
    ok: true,
    headers: new Map(),
  })));
  const r = await clientRequest(19620, "/buffered?x=1");
  assert.equal(r.status, 200);
  assert.equal(r.body, "GET /buffered?x=1");
});

test("http.createServer: a streaming async handler writes through AsyncResponseWriter", async () => {
  servers.push(http.createServer(19621, async (req, res) => {
    await res.writeHead(201, new Map([["x-tag", "hi"]]));
    await res.write("a-");
    await res.write(req.path);
    await res.end();
  }));
  const r = await clientRequest(19621, "/streamed");
  assert.equal(r.status, 201);
  assert.equal(r.body, "a-/streamed");
});

test("http.createServer: two connections make progress concurrently, one does not stall the other", async () => {
  // Same property spec 511 exists to prove for net.createServer: a client
  // that opens a connection and never finishes sending its request must
  // not block a second, complete request on the same listener. A version
  // of this feature that serialized requests behind one shared listener
  // loop would make the fast request wait for the slow one's timeout.
  servers.push(http.createServer(19622, async (req) => ({ status: 200, body: req.path, ok: true, headers: new Map() })));

  const started = Date.now();
  const slow = new Promise((resolve, reject) => {
    const sock = nnet.connect(19622, "127.0.0.1", () => {
      sock.write("GET /slow HTTP/1.1\r\nHost: x\r\n"); // headers deliberately incomplete
      setTimeout(() => sock.write("Connection: close\r\n\r\n"), 300);
    });
    let buf = "";
    sock.on("data", (d) => (buf += d.toString()));
    sock.on("end", () => resolve(Date.now() - started));
    sock.on("error", reject);
  });

  await new Promise((r) => setTimeout(r, 50)); // give the slow connection a head start
  const fast = await clientRequest(19622, "/fast");
  const fastMs = Date.now() - started;
  assert.equal(fast.status, 200);
  assert.equal(fast.body, "/fast");
  assert.ok(fastMs < 250, `fast request took ${fastMs}ms, expected well under the slow connection's 300ms`);
  await slow; // let the slow connection finish before the test ends
});

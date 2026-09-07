// `net.connect`/`Socket` (spec 054), wired to the spec 508 I/O broker.
// Mirrors `LumenSocket` (src/lumen_runtime_net.zig): a failed connect never
// throws, degrading instead to a dead handle whose read()/write()/close()
// are no-ops/empty results.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import * as net from "../lib/net.mjs";
import { shutdownBridge } from "../lib/broker/sync_bridge.mjs";

after(() => shutdownBridge());

const PEER = fileURLToPath(new URL("./fixtures/broker_peer.mjs", import.meta.url));

function startPeer(...args) {
  const child = spawn(process.execPath, [PEER, ...args]);
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

test("connect/write/read round-trips bytes with a real peer, close is idempotent", async () => {
  const { child, port } = await startPeer("echo");
  try {
    const sock = net.connect("127.0.0.1", port);
    sock.write("ping");
    assert.equal(sock.read(), "ping");
    sock.close();
    sock.close(); // idempotent, like LumenSocket.close
  } finally {
    child.kill();
  }
});

test("read() returns \"\" at end of stream", async () => {
  const { child, port } = await startPeer("dump", Buffer.from("bye").toString("base64"));
  try {
    const sock = net.connect("127.0.0.1", port);
    assert.equal(sock.read(), "bye");
    assert.equal(sock.read(), "");
    sock.close();
  } finally {
    child.kill();
  }
});

test("a failed connect never throws: read()/write()/close() on the dead socket are no-ops/empty, exactly as LumenSocket's null-stream fallback", () => {
  // Nothing listens here; connect must fail fast and the socket must
  // degrade gracefully rather than throw (src/lumen_runtime_net.zig's
  // __netConnect never throws either).
  const sock = net.connect("127.0.0.1", 1);
  assert.equal(sock.read(), "");
  assert.doesNotThrow(() => sock.write("anything"));
  assert.doesNotThrow(() => sock.close());
});

test("net.createServer is refused at run time (also refused at compile time, permanently, by the checker/emitter)", () => {
  assert.throws(() => net.createServer(), /net\.createServer is not supported on the node target/);
});

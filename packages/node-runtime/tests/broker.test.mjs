// The spec 508 broker: promoted from packages/node-runtime/spike/ into
// lib/broker/. Covers, at minimum, the two Node behaviours the spike found
// (Atomics.waitAsync needs an explicit keep-alive; every socket listener
// must attach in the socket's own synchronous turn) as regression tests,
// per this spec's plan.md "Verification" section.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import * as P from "../lib/broker/protocol.mjs";
import { call, shutdownBroker } from "../lib/broker/singleton.mjs";
import { syncSleep, syncConnect, syncRead, syncWrite, syncClose, shutdownBridge } from "../lib/broker/sync_bridge.mjs";

after(() => shutdownBridge());

const PEER = fileURLToPath(new URL("./fixtures/broker_peer.mjs", import.meta.url));

/** Starts tests/fixtures/broker_peer.mjs and resolves once it has printed
 *  the port it is listening on. */
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

test("syncSleep(ms) blocks the calling thread for at least ms, never undershooting (spec 475's contract; spec 508's re-arm fix for the spike's 0.34ms undershoot)", () => {
  for (const ms of [1, 5, 13, 30]) {
    const t0 = performance.now();
    syncSleep(ms);
    const elapsed = performance.now() - t0;
    assert.ok(elapsed >= ms, `slept only ${elapsed}ms for a ${ms}ms request`);
  }
});

test("the broker keeps answering across many sequential requests with nothing else scheduled (Atomics.waitAsync keep-alive regression)", () => {
  // Without the broker's inert setInterval, Atomics.waitAsync's promise
  // does not keep the worker's event loop alive and the worker exits after
  // the first request, so every call after that would time out instead of
  // answering -- the exact failure this loop would surface.
  for (let i = 0; i < 25; i++) {
    const { status } = call(P.OP_SLEEP, P.encodeSleepArgs(0), 2000);
    assert.equal(status, 0);
  }
});

test("a fast peer's data and EOF both survive the bridge (same-synchronous-turn listener regression)", async () => {
  const payload = Buffer.from("hello from a fast peer that writes then ends synchronously");
  const { child, port } = await startPeer("dump", payload.toString("base64"));
  try {
    const handle = syncConnect("127.0.0.1", port);
    const chunks = [];
    for (;;) {
      const chunk = syncRead(handle);
      if (chunk.length === 0) break;
      chunks.push(chunk);
    }
    assert.deepEqual(Buffer.concat(chunks), payload);
    syncClose(handle);
  } finally {
    child.kill();
  }
});

test("syncWrite round-trips bytes to a real peer", async () => {
  const { child, port } = await startPeer("echo");
  try {
    const handle = syncConnect("127.0.0.1", port);
    const sent = Buffer.from("ping");
    syncWrite(handle, sent);
    const echoed = syncRead(handle);
    assert.deepEqual(echoed, sent);
    syncClose(handle);
  } finally {
    child.kill();
  }
});

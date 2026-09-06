// The blocking surfaces' synchronous API (spec 508): every call here
// genuinely blocks this thread's event loop -- no timer, no I/O callback,
// no console.log flush runs until the broker answers -- via the singleton
// broker's `Atomics.wait`. `lib/process.mjs`, `lib/net.mjs`, `lib/http.mjs`,
// `lib/child_process.mjs` call into this; nothing else should reach for
// `broker/singleton.mjs` or `broker/protocol.mjs` directly.
import { call, shutdownBroker } from "./singleton.mjs";
import * as P from "./protocol.mjs";

export function syncSleep(ms) {
  call(P.OP_SLEEP, P.encodeSleepArgs(ms));
}

export function syncConnect(host, port) {
  const { status, bytes } = call(P.OP_CONNECT, P.encodeConnectArgs(host, port));
  if (status !== 0) throw new Error("net.connect failed");
  return P.decodeConnectResult(bytes);
}

// Mirrors Socket.read() (spec 054): the next chunk, empty at EOF.
export function syncRead(handle) {
  const { status, bytes } = call(P.OP_READ, P.encodeHandleArgs(handle));
  if (status < 0) throw new Error("socket read failed, status " + status);
  return bytes;
}

export function syncWrite(handle, buf) {
  call(P.OP_WRITE, P.encodeWriteArgs(handle, buf));
}

export function syncClose(handle) {
  call(P.OP_CLOSE, P.encodeHandleArgs(handle));
}

/** Terminates the broker worker, if one was ever started. Tests only -- a
 *  real program lets the (unref'd) worker exit with the process. */
export function shutdownBridge() {
  shutdownBroker();
}

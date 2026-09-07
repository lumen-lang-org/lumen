// The blocking surfaces' synchronous API (spec 508): every call here
// genuinely blocks this thread's event loop -- no timer, no I/O callback,
// no console.log flush runs until the broker answers -- via the singleton
// broker's `Atomics.wait`. `lib/process.mjs`, `lib/net.mjs`, `lib/http.mjs`,
// `lib/child_process.mjs` call into this; nothing else should reach for
// `broker/singleton.mjs` or `broker/protocol.mjs` directly.
import { call, shutdownBroker } from "./singleton.mjs";
import * as P from "./protocol.mjs";
// The real Node `Buffer`, not the ambient global -- see protocol.mjs's own
// comment: `globals.mjs` replaces `globalThis.Buffer` with `LumenBuffer`
// (spec 056) on this (the calling) thread for every Lumen program.
import { Buffer } from "node:buffer";

/** Every handle-opening call below (`syncConnect`, `syncHttpStreamOpen`,
 *  `syncSpawn`) returns this sentinel on failure instead of throwing: the
 *  native runtime never throws on a failed connect/spawn/stream-open
 *  either (`LumenSocket`/`LumenHttpStream`/`LumenChildProcess` all degrade
 *  to a handle whose stream/child is `null`, "always read empty, write is
 *  a no-op"). `lib/net.mjs`/`lib/http.mjs`/`lib/child_process.mjs` give
 *  every method on a dead handle that exact same no-op/empty-result
 *  behavior without ever reaching the broker again.
 */
export const DEAD_HANDLE = -1;

export function syncSleep(ms) {
  call(P.OP_SLEEP, P.encodeSleepArgs(ms));
}

export function syncConnect(host, port) {
  const { status, bytes } = call(P.OP_CONNECT, P.encodeConnectArgs(host, port));
  return status === 0 ? P.decodeHandleResult(bytes) : DEAD_HANDLE;
}

// Mirrors Socket.read() (spec 054): the next chunk, empty at EOF or on any
// read error -- native's LumenSocket.read() never distinguishes the two,
// both fall through to "".
export function syncRead(handle) {
  const { status, bytes } = call(P.OP_READ, P.encodeHandleArgs(handle));
  return status < 0 ? Buffer.alloc(0) : bytes;
}

export function syncWrite(handle, buf) {
  call(P.OP_WRITE, P.encodeWriteArgs(handle, buf));
}

export function syncClose(handle) {
  call(P.OP_CLOSE, P.encodeHandleArgs(handle));
}

// ---------------------------------------------------------------------------
// child_process.spawn (spec 450) and http.stream (spec 452) share these:
// readLine (line-buffered, keeps the "\n"), writeLine (child stdin only).

export function syncReadLine(handle) {
  const { status, bytes } = call(P.OP_READLINE, P.encodeHandleArgs(handle));
  return status < 0 ? Buffer.alloc(0) : bytes;
}

export function syncWriteLine(handle, buf) {
  call(P.OP_WRITELINE, P.encodeWritelineArgs(handle, buf));
}

// ---------------------------------------------------------------------------
// http.request / http.get (spec 042): one buffered round trip, no handle.

export function syncHttpRequest(url, method, body, headers) {
  const { bytes } = call(P.OP_HTTP_REQUEST, P.encodeHttpOpenArgs(url, method, body, headers));
  return P.decodeHttpResponseResult(bytes);
}

// ---------------------------------------------------------------------------
// http.stream (spec 452): a live handle.

export function syncHttpStreamOpen(url, method, body, headers) {
  const { status, bytes } = call(P.OP_HTTP_STREAM_OPEN, P.encodeHttpOpenArgs(url, method, body, headers));
  return status === 0 ? P.decodeHandleResult(bytes) : DEAD_HANDLE;
}

export function syncHttpStatus(handle) {
  const { bytes } = call(P.OP_HTTP_STATUS, P.encodeHandleArgs(handle));
  return P.decodeStatusResult(bytes);
}

export function syncHttpHeader(handle, name) {
  const { bytes } = call(P.OP_HTTP_HEADER, P.encodeHeaderArgs(handle, name));
  return bytes;
}

export function syncHttpDone(handle) {
  const { bytes } = call(P.OP_HTTP_DONE, P.encodeHandleArgs(handle));
  return P.decodeBoolResult(bytes);
}

// ---------------------------------------------------------------------------
// child_process.spawn (spec 450): a live handle.

export function syncSpawn(command, args) {
  const { status, bytes } = call(P.OP_SPAWN, P.encodeSpawnArgs(command, args));
  return status === 0 ? P.decodeHandleResult(bytes) : DEAD_HANDLE;
}

/** Terminates the broker worker, if one was ever started. Tests only -- a
 *  real program lets the (unref'd) worker exit with the process. */
export function shutdownBridge() {
  shutdownBroker();
}

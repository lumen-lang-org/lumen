// The non-blocking surfaces' API (spec 511): unlike `sync_bridge.mjs`
// (spec 508 — every call there genuinely blocks this thread until the
// broker answers), the calls here `await` a per-handle control block via
// `Atomics.waitAsync`, so this thread's event loop keeps running other
// handles' pending calls, timers and I/O while one is outstanding. Only
// `net.createServer`/`http.createServer` (`lib/net.mjs`, `lib/http.mjs`)
// call into this; a program with no server has no per-handle control
// blocks to speak of and never reaches these functions.
import { call, callHandle, onAccept as brokerOnAccept } from "./singleton.mjs";
import * as P from "./protocol.mjs";
import { Buffer } from "node:buffer";

/** See `sync_bridge.mjs`'s own `DEAD_HANDLE` doc: the same sentinel, same
 *  meaning -- a failed listen degrades to a dead handle rather than
 *  throwing, matching every other open call this package makes. */
export const DEAD_HANDLE = -1;

/** Starts listening on `port`, returning a listener id (or `DEAD_HANDLE`).
 *  One-shot and brief, so this uses the ordinary blocking `call()` (spec
 *  508) rather than the async path below -- there is nothing to run
 *  concurrently with a listen that happens once, synchronously, before any
 *  connection can exist yet. */
export function asyncListen(port) {
  const { status, bytes } = call(P.OP_LISTEN, P.encodeListenArgs(port));
  return status === 0 ? P.decodeHandleResult(bytes) : DEAD_HANDLE;
}

/** Registers `onConn(handle, controlSAB, dataSAB)` for every connection
 *  accepted on `listenerId`. See `singleton.mjs`'s own doc: this also
 *  keeps the calling thread alive indefinitely (matching native's
 *  `noreturn` `http.createServer`), since a listener has no bounded wait
 *  of its own to keep the process up the way every other blocking call
 *  does. */
export const onAccept = brokerOnAccept;

/** Mirrors `sync_bridge.mjs`'s `syncRead`: the next chunk, empty at EOF or
 *  on any read error -- never throws. */
export async function asyncRead(handle, controlSAB, dataSAB) {
  const { status, bytes } = await callHandle(controlSAB, dataSAB, P.OP_READ, P.encodeHandleArgs(handle));
  return status < 0 ? Buffer.alloc(0) : bytes;
}

export async function asyncWrite(handle, controlSAB, dataSAB, buf) {
  await callHandle(controlSAB, dataSAB, P.OP_WRITE, P.encodeWriteArgs(handle, buf));
}

export async function asyncClose(handle, controlSAB, dataSAB) {
  await callHandle(controlSAB, dataSAB, P.OP_CLOSE, P.encodeHandleArgs(handle));
}

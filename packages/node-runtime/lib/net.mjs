// `net.*` (specs 054, 490): raw TCP sockets. `net.connect` blocks for the
// connection and returns a `Socket` wired to the spec 508 I/O broker,
// mirroring `LumenSocket` (src/lumen_runtime_net.zig): a failed connect
// never throws, it degrades to a dead handle whose `read()`/`write()`/
// `close()` are the same "always empty / no-op" fallback the native struct
// gives a null `stream`.
//
// `net.createServer` (spec 511): each accepted connection gets its own
// broker-side control block (`async_bridge.mjs`), so many concurrent
// connections' reads/writes never serialize behind one shared one the way
// every other blocking call in this package still correctly does (a Lumen
// thread only ever has one outstanding call of ITS OWN at a time; a server
// genuinely needs many connections in flight together). The checker only
// accepts an `async` handler on this target (spec 511 T007) -- calling it
// per connection without `await`ing it here, letting each run
// independently, is what actually delivers that concurrency; `await`ing it
// in the accept callback would silently serialize every connection behind
// whichever one is currently running, exactly the bug this spec exists to
// fix.
import { DEAD_HANDLE, syncConnect, syncRead, syncWrite, syncClose } from "./broker/sync_bridge.mjs";
import { asyncListen, onAccept, asyncRead, asyncWrite, asyncClose, DEAD_HANDLE as ASYNC_DEAD_HANDLE } from "./broker/async_bridge.mjs";
import { fromBuffer, toBuffer } from "./lang.mjs";

class Socket {
  #handle;
  constructor(handle) {
    this.#handle = handle;
  }
  /** The next chunk, "" at EOF, on any read error, or on a dead handle
   *  (spec 054). */
  read() {
    if (this.#handle === DEAD_HANDLE) return "";
    return fromBuffer(syncRead(this.#handle));
  }
  /** Writes `chunk`'s raw bytes; a no-op on a dead handle. */
  write(chunk) {
    if (this.#handle === DEAD_HANDLE) return;
    syncWrite(this.#handle, toBuffer(chunk));
  }
  /** Idempotent, like the native `LumenSocket.close`. */
  close() {
    if (this.#handle === DEAD_HANDLE) return;
    syncClose(this.#handle);
    this.#handle = DEAD_HANDLE;
  }
}

export function connect(host, port) {
  return new Socket(syncConnect(host, Number(port)));
}

/** The `async`-handler-only socket a `createServer` connection hands its
 *  handler (spec 511): same shape as `Socket` above, but every operation
 *  is `await`-able instead of blocking, backed by this ONE connection's own
 *  control block rather than the shared process-wide one. */
class AsyncSocket {
  #handle;
  #controlSAB;
  #dataSAB;
  constructor(handle, controlSAB, dataSAB) {
    this.#handle = handle;
    this.#controlSAB = controlSAB;
    this.#dataSAB = dataSAB;
  }
  async read() {
    if (this.#handle === ASYNC_DEAD_HANDLE) return "";
    return fromBuffer(await asyncRead(this.#handle, this.#controlSAB, this.#dataSAB));
  }
  async write(chunk) {
    if (this.#handle === ASYNC_DEAD_HANDLE) return;
    await asyncWrite(this.#handle, this.#controlSAB, this.#dataSAB, toBuffer(chunk));
  }
  async close() {
    if (this.#handle === ASYNC_DEAD_HANDLE) return;
    await asyncClose(this.#handle, this.#controlSAB, this.#dataSAB);
    this.#handle = ASYNC_DEAD_HANDLE;
  }
}

/** `net.createServer(port, async (socket) => {...})` (spec 511). A failed
 *  listen (e.g. the port is already in use) exits the process the same
 *  blunt way native does (`std.process.exit(1)` on a failed `addr.listen`,
 *  `src/lumen_runtime_net.zig`) rather than degrading to a dead handle --
 *  unlike a failed connect, there is no sensible "always empty" fallback
 *  for a server that never bound its port at all. */
export function createServer(port, handler) {
  const listenerId = asyncListen(Number(port));
  if (listenerId === ASYNC_DEAD_HANDLE) process.exit(1);
  onAccept(listenerId, (handle, controlSAB, dataSAB) => {
    const socket = new AsyncSocket(handle, controlSAB, dataSAB);
    Promise.resolve(handler(socket)).catch(() => {});
  });
}

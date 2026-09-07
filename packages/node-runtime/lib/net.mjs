// `net.*` (specs 054, 490): raw TCP sockets. `net.connect` blocks for the
// connection and returns a `Socket` wired to the spec 508 I/O broker,
// mirroring `LumenSocket` (src/lumen_runtime_net.zig): a failed connect
// never throws, it degrades to a dead handle whose `read()`/`write()`/
// `close()` are the same "always empty / no-op" fallback the native struct
// gives a null `stream`.
//
// `net.createServer` needs a per-connection OS thread with handlers sharing
// module state, which Node's isolate-per-thread model cannot give without
// giving up shared state (spec 508's Decision, point 3) -- rejected at
// compile time (`unsupportedStaticCall`), not here.
import { DEAD_HANDLE, syncConnect, syncRead, syncWrite, syncClose } from "./broker/sync_bridge.mjs";
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

export function createServer() {
  throw new Error("net.createServer is not supported on the node target (spec 508: no async handler form yet)");
}

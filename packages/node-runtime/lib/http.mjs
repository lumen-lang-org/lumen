// `http.*` (specs 042, 049, 355, 452). `request`/`get` are one buffered
// round trip over the spec 508 broker (never throws; a failed request
// degrades to `{ status: -1, ok: false, headers: <empty> }`, mirroring
// `__httpRequest`'s fetch-failure fallback in src/lumen_runtime_net.zig).
// `stream` is a live read handle wired the same way `net.connect` is,
// mirroring `LumenHttpStream` (same file): a live handle's `write()`/
// `read()` reach the raw connection for a post-101 WebSocket upgrade (specs
// 494, 495); everything else reads it through `readLine()`.
//
// Response headers on the buffered client are deliberately not surfaced,
// exactly as they are not natively (see `__httpRequest`'s own comment): the
// buffered call always answers an empty `headers` map on both targets.
//
// `http.createServer` needs a per-request OS thread with handlers sharing
// module state, which Node's isolate-per-thread model cannot give without
// giving up shared state (spec 508's Decision, point 3) -- rejected at
// compile time (`unsupportedStaticCall`), not here.
import nhttp from "node:http";
import { fromBuffer, toBuffer } from "./lang.mjs";
import {
  DEAD_HANDLE,
  syncHttpRequest,
  syncHttpStreamOpen,
  syncHttpStatus,
  syncHttpHeader,
  syncHttpDone,
  syncRead,
  syncReadLine,
  syncWrite,
  syncClose,
} from "./broker/sync_bridge.mjs";

const METHOD_LIST = Object.freeze([
  "ACL", "BIND", "CHECKOUT", "CONNECT", "COPY", "DELETE",
  "GET", "HEAD", "LINK", "LOCK", "M-SEARCH", "MERGE",
  "MKACTIVITY", "MKCALENDAR", "MKCOL", "MOVE", "NOTIFY", "OPTIONS",
  "PATCH", "POST", "PROPFIND", "PROPPATCH", "PURGE", "PUT",
  "QUERY", "REBIND", "REPORT", "SEARCH", "SOURCE", "SUBSCRIBE",
  "TRACE", "UNBIND", "UNLINK", "UNLOCK", "UNSUBSCRIBE",
]);

// `url`, `method`, `body` and every key/value of the `headers` Map arrive
// as Lumen strings -- already latin1-per-byte JavaScript strings (spec
// 505) -- so they cross into `protocol.mjs`'s `Buffer.from(s, "latin1")`
// encoders exactly as they are, the same way `syncConnect(host, port)`
// passes `host` straight through. Only bytes coming back off the wire (a
// response body, a header value, a stream read/readLine) need `fromBuffer`
// to become a Lumen string.

function buffered(url, method, body, headers) {
  const { status, ok, body: respBody } = syncHttpRequest(url, method, body, headers);
  return { status, ok, body: fromBuffer(respBody), headers: new Map() };
}

export function request(url, method, body, headers) {
  return buffered(url, method, body, headers);
}

export function get(url) {
  return buffered(url, "GET", "", new Map());
}

class HttpStream {
  #handle;
  constructor(handle) {
    this.#handle = handle;
  }
  status() {
    return this.#handle === DEAD_HANDLE ? -1 : syncHttpStatus(this.#handle);
  }
  header(name) {
    if (this.#handle === DEAD_HANDLE) return "";
    return fromBuffer(syncHttpHeader(this.#handle, name));
  }
  /** The next decoded body line, terminator kept; "" once exhausted or on
   *  a dead handle. */
  readLine() {
    if (this.#handle === DEAD_HANDLE) return "";
    return fromBuffer(syncReadLine(this.#handle));
  }
  /** One raw, undelimited read off the same connection (spec 495). */
  read() {
    if (this.#handle === DEAD_HANDLE) return "";
    return fromBuffer(syncRead(this.#handle));
  }
  /** Raw bytes on the connection, past a 101 upgrade (spec 494). */
  write(chunk) {
    if (this.#handle === DEAD_HANDLE) return;
    syncWrite(this.#handle, toBuffer(chunk));
  }
  done() {
    return this.#handle === DEAD_HANDLE ? true : syncHttpDone(this.#handle);
  }
  close() {
    if (this.#handle === DEAD_HANDLE) return;
    syncClose(this.#handle);
    this.#handle = DEAD_HANDLE;
  }
}

export function stream(url, method, body, headers) {
  const handle = syncHttpStreamOpen(url, method, body, headers);
  return new HttpStream(handle);
}

export function createServer() {
  throw new Error("http.createServer is not supported on the node target (spec 508: no async handler form yet)");
}

export function METHODS() {
  return METHOD_LIST.slice();
}

/** `Map<int, string>` of reason phrases. */
export function STATUS_CODES() {
  const m = new Map();
  for (const [code, reason] of Object.entries(nhttp.STATUS_CODES)) m.set(Number(code), reason);
  return m;
}

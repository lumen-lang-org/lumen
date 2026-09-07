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
// `http.createServer` (spec 511 T012): both the buffered and streaming
// handler forms get a real, non-blocking implementation, each with an
// `async` counterpart mirroring `net.createServer`'s own sync/async split
// (spec 511 decision 1: native stays sync-only, node is async-only).
// Unlike `net.createServer` (T003/T011), this never touches the spec 508
// broker at all: it runs directly on Node's own `http.Server`, on the
// calling thread's event loop. Node's own HTTP parsing/framing/keep-alive
// is exactly the free, battle-tested layer a hand-rolled one over a raw
// broker `Socket` would otherwise have to reimplement, and a plain
// `server.listen(port)` already keeps the process alive on its own --
// no `ref()`/`unref()` juggling of the kind `net.createServer`'s
// broker-worker-thread listener needs (`singleton.mjs`'s `onAccept`).
import nhttp from "node:http";
import { Buffer } from "node:buffer";
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

/** The streaming handler's second argument (spec 511 T012): every
 *  operation is `await`-able, mirroring `net.mjs`'s own `Socket` ->
 *  `AsyncSocket` split -- `checker`-guaranteed real type, not "ResponseWriter
 *  used inside an async function". Wraps Node's `http.ServerResponse`
 *  directly: `write`/`writeHead` are synchronous there already (Node
 *  buffers internally), so wrapping them in `async` costs nothing and
 *  keeps the surface uniform with `Socket.write()`'s own `await`. */
class AsyncResponseWriter {
  #res;
  constructor(res) {
    this.#res = res;
  }
  async writeHead(status, headers) {
    this.#res.writeHead(status, Object.fromEntries(headers));
  }
  async write(chunk) {
    this.#res.write(toBuffer(chunk));
  }
  async end() {
    this.#res.end();
  }
}

/** Buffers a request body to completion (native's own accept loop reads a
 *  request fully before invoking a handler too -- neither handler form
 *  streams the incoming body, only the outgoing response). */
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

/** Node's raw `IncomingMessage` -> the `__LumenHttpRequest` record shape
 *  (spec 459): header names arrive already lowercased from Node, matching
 *  `registerLumenHttpRequest`'s own documented contract; a header repeated
 *  on the wire arrives as an array from Node and is joined with ", "
 *  (except `cookie`, which Node itself already joins with "; "), the same
 *  folding `Map<string,string>` forces everywhere else in this package. */
function toLumenRequest(req, bodyBuf) {
  const headers = new Map();
  for (const [k, v] of Object.entries(req.headers)) {
    headers.set(k, Array.isArray(v) ? v.join(", ") : String(v ?? ""));
  }
  return { method: req.method, path: req.url, body: fromBuffer(bodyBuf), headers };
}

/** `http.createServer(port, handler)` (spec 452, 511 T012): `handler`'s own
 *  arity selects buffered (`(req) => HttpResponse`) vs. streaming
 *  (`(req, res) => void`), exactly like the checker's own
 *  `httpServerHandlerIsAsync` -- the checker guarantees whichever shape
 *  reaches here is a named `async function` returning the right thing, so
 *  this never re-validates it, the same trust `net.mjs`'s own
 *  `createServer` places in its own checker-guaranteed shape.
 *
 *  Each request handler runs independently, not serialized behind one
 *  shared per-listener state, the same concurrency `net.createServer`
 *  exists for (spec 511's whole point) -- Node's own `http.Server` already
 *  gives this for free, one request at a time per connection but many
 *  connections (and, with keep-alive, many requests) truly concurrently on
 *  this one thread's event loop. A handler that throws fails only its own
 *  request (a 500, if nothing was sent yet) rather than crashing the
 *  listener -- mirrors `net.createServer`'s own per-connection
 *  `.catch(() => {})`. */
export function createServer(port, handler) {
  const streaming = handler.length === 2;
  const server = nhttp.createServer((req, res) => {
    readBody(req)
      .then(async (bodyBuf) => {
        const lumenReq = toLumenRequest(req, bodyBuf);
        if (streaming) {
          await handler(lumenReq, new AsyncResponseWriter(res));
        } else {
          const resp = await handler(lumenReq);
          res.writeHead(resp.status, Object.fromEntries(resp.headers));
          res.end(toBuffer(resp.body));
        }
      })
      .catch(() => {
        try {
          if (!res.headersSent) res.writeHead(500);
          res.end();
        } catch {
          // The connection is already gone; nothing left to answer.
        }
      });
  });
  server.listen(port);
  // Lumen's own checked type for this call is `void` (matching native's
  // `noreturn` accept loop -- a real program never stops a server it
  // starts), so no compiled code will ever see or use this return value.
  // Returned anyway, JS-side only, so tests can `.close()` what they
  // start instead of leaking a live listener into every later test in the
  // same process -- unlike `net.createServer` (spec 511 T003/T011), whose
  // listener lives on the broker worker thread and goes away with
  // `shutdownBridge()`, this one runs directly on the calling thread, so
  // there is no shared cleanup hook to piggyback on here.
  return server;
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

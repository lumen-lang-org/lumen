// `http.*` (specs 042, 049, 355, 452). The client and server calls block
// (spec 508); `METHODS()` and `STATUS_CODES()` are the constant tables,
// pinned to the lists the native runtime carries (Node's own, verbatim).
import nhttp from "node:http";

const METHOD_LIST = Object.freeze([
  "ACL", "BIND", "CHECKOUT", "CONNECT", "COPY", "DELETE",
  "GET", "HEAD", "LINK", "LOCK", "M-SEARCH", "MERGE",
  "MKACTIVITY", "MKCALENDAR", "MKCOL", "MOVE", "NOTIFY", "OPTIONS",
  "PATCH", "POST", "PROPFIND", "PROPPATCH", "PURGE", "PUT",
  "QUERY", "REBIND", "REPORT", "SEARCH", "SOURCE", "SUBSCRIBE",
  "TRACE", "UNBIND", "UNLINK", "UNLOCK", "UNSUBSCRIBE",
]);

export function request() {
  throw new Error("http.request needs the I/O broker, spec 508");
}

export function get() {
  throw new Error("http.get needs the I/O broker, spec 508");
}

export function stream() {
  throw new Error("http.stream needs the I/O broker, spec 508");
}

export function createServer() {
  throw new Error("http.createServer needs the I/O broker, spec 508");
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

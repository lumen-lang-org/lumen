// Shared wire format between the main thread and the broker worker (spec
// 508). `control` is an `Int32Array(CONTROL_WORDS)` over a SharedArrayBuffer:
// one word each for the state machine, a diagnostic request id, the op
// code, and the argument/response lengths and status. `data` is a second
// SharedArrayBuffer carrying the raw argument bytes on the way in and the
// raw response bytes on the way out -- a request and its response never
// overlap in time (the state machine below forbids it), so both directions
// reuse the same region.
//
// Explicitly imported, real `node:buffer` `Buffer` -- NOT the ambient
// global. `globals.mjs` replaces `globalThis.Buffer` with Lumen's own
// `LumenBuffer` (spec 056) for every program it installs into, on whichever
// thread it runs: the main thread always (both the compiled entry's static
// `import "@lumen-lang/node/globals"` and a hand-run `node --import
// .../globals.mjs prog.ts` install it there), and -- found the hard way,
// debugging a corrupted `child_process.spawn` argument under exactly the
// `--import` invocation -- a broker worker too, since Node's workers
// inherit `process.execArgv` (which carries `--import`) unless told not to.
// `LumenBuffer.from(arrayBuffer, byteOffset, length)` silently drops the
// last two arguments (its own `from` only takes two parameters), so this
// module's `Buffer.from(someArrayBuffer, offset, length)` calls would
// decode the *whole* buffer instead of the requested slice whenever the
// ambient `Buffer` happened to be `LumenBuffer` -- and `Buffer.byteLength`
// doesn't exist on it at all. Binding the real one here, once, makes every
// call below correct regardless of what `globalThis.Buffer` is on
// whichever thread happens to run it.
import { Buffer } from "node:buffer";

export const STATE = 0;
export const REQ_ID = 1;
export const OP = 2;
export const ARG_LEN = 3;
export const RESP_LEN = 4;
export const RESP_STATUS = 5;
export const CONTROL_WORDS = 6;

export const IDLE = 0;
export const REQUEST_POSTED = 1;
export const RESPONSE_READY = 2;

export const OP_SLEEP = 1;
export const OP_CONNECT = 2;
export const OP_READ = 3;
export const OP_WRITE = 4;
export const OP_CLOSE = 5;
// Generic across handle kinds (socket, http-stream, child-process): the
// broker dispatches by what kind the handle was opened as.
export const OP_READLINE = 6;
export const OP_WRITELINE = 7; // child-process only: write(data) + "\n"
// http.request/get (spec 042): one buffered round trip, no handle.
export const OP_HTTP_REQUEST = 8;
// http.stream (spec 452): a live handle, opened the same shape as connect.
export const OP_HTTP_STREAM_OPEN = 9;
export const OP_HTTP_STATUS = 10;
export const OP_HTTP_HEADER = 11;
export const OP_HTTP_DONE = 12;
// child_process.spawn (spec 450): a live handle, opened the same shape as connect.
export const OP_SPAWN = 13;

// Headroom over the 64KB chunk spec 054 documents, plus each op's own small
// fixed header (see the encoders below) -- both directions share this one
// region, so it has to fit the larger of a request and its response.
export const DATA_BYTES = 70 * 1024;

// Fixed-layout binary encoding per op, little-endian throughout. Replaces
// the spike's `JSON.stringify`/`parse`, which sat on every call's critical
// path (the spike measured 1.3-2.8ms/call of overhead) encoding argument
// shapes plain field access already covers.

/** OP_SLEEP: the duration in milliseconds, as sent to `process.sleep` --
 *  spec 475 allows any integer, so this is a float64, not a smaller int. */
export function encodeSleepArgs(ms) {
  const out = new Uint8Array(8);
  new DataView(out.buffer).setFloat64(0, ms, true);
  return out;
}
export function decodeSleepArgs(bytes) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getFloat64(0, true);
}

/** OP_CONNECT args: `[port: u32][hostLen: u16][host bytes]`. Host names are
 *  ASCII/latin1 in practice (spec 054 does not offer IDN), so this uses the
 *  same byte-per-char encoding Lumen strings use elsewhere in the package. */
export function encodeConnectArgs(host, port) {
  const hostBytes = Buffer.from(host, "latin1");
  const out = new Uint8Array(6 + hostBytes.length);
  new DataView(out.buffer).setUint32(0, port, true);
  new DataView(out.buffer).setUint16(4, hostBytes.length, true);
  out.set(hostBytes, 6);
  return out;
}
export function decodeConnectArgs(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const port = view.getUint32(0, true);
  const hostLen = view.getUint16(4, true);
  const host = Buffer.from(bytes.buffer, bytes.byteOffset + 6, hostLen).toString("latin1");
  return { host, port };
}

/** A new handle, a `u32`, on success -- OP_CONNECT, OP_HTTP_STREAM_OPEN and
 *  OP_SPAWN all open a long-lived handle the exact same way. */
export function encodeConnectResult(handle) {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, handle, true);
  return out;
}
export function decodeConnectResult(bytes) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(0, true);
}
export const encodeHandleResult = encodeConnectResult;
export const decodeHandleResult = decodeConnectResult;

/** OP_READ and OP_CLOSE args: just the handle, a `u32`. */
export function encodeHandleArgs(handle) {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, handle, true);
  return out;
}
export function decodeHandleArgs(bytes) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(0, true);
}

/** OP_WRITE args: `[handle: u32][payload bytes]`. The payload is already
 *  raw bytes, so it is appended as-is rather than re-encoded. */
export function encodeWriteArgs(handle, payload) {
  const out = new Uint8Array(4 + payload.length);
  new DataView(out.buffer).setUint32(0, handle, true);
  out.set(payload, 4);
  return out;
}
export function decodeWriteArgs(bytes) {
  const handle = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(0, true);
  return { handle, payload: bytes.subarray(4) };
}
// OP_WRITELINE shares OP_WRITE's exact wire shape (handle + payload, the
// broker appends "\n" itself); no separate encoder needed.
export const encodeWritelineArgs = encodeWriteArgs;
export const decodeWritelineArgs = decodeWriteArgs;

/** OP_HTTP_HEADER args: `[handle: u32][name bytes]` (name is the last field,
 *  so its length is implicit -- the whole rest of the argument buffer). */
export function encodeHeaderArgs(handle, name) {
  const nameBytes = Buffer.from(name, "latin1");
  const out = new Uint8Array(4 + nameBytes.length);
  new DataView(out.buffer).setUint32(0, handle, true);
  out.set(nameBytes, 4);
  return out;
}
export function decodeHeaderArgs(bytes) {
  const handle = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(0, true);
  const name = Buffer.from(bytes.buffer, bytes.byteOffset + 4, bytes.byteLength - 4).toString("latin1");
  return { handle, name };
}

/** Header count (u16), then that many `[keyLen: u16][key][valLen: u16][val]`
 *  entries -- shared by OP_HTTP_REQUEST and OP_HTTP_STREAM_OPEN, whose
 *  headers argument is a Lumen `Map<string, string>` (a real JS `Map` on
 *  Node, spec 505). */
function writeHeaders(view, out, offset, headers) {
  view.setUint16(offset, headers.size, true);
  offset += 2;
  for (const [k, v] of headers) {
    const kb = Buffer.from(k, "latin1");
    const vb = Buffer.from(v, "latin1");
    view.setUint16(offset, kb.length, true);
    offset += 2;
    out.set(kb, offset);
    offset += kb.length;
    view.setUint16(offset, vb.length, true);
    offset += 2;
    out.set(vb, offset);
    offset += vb.length;
  }
  return offset;
}
function headersByteLength(headers) {
  let n = 2;
  for (const [k, v] of headers) n += 4 + Buffer.byteLength(k, "latin1") + Buffer.byteLength(v, "latin1");
  return n;
}
function readHeaders(view, bytes, offset) {
  const count = view.getUint16(offset, true);
  offset += 2;
  const headers = new Map();
  for (let i = 0; i < count; i++) {
    const kLen = view.getUint16(offset, true);
    offset += 2;
    const k = Buffer.from(bytes.buffer, bytes.byteOffset + offset, kLen).toString("latin1");
    offset += kLen;
    const vLen = view.getUint16(offset, true);
    offset += 2;
    const v = Buffer.from(bytes.buffer, bytes.byteOffset + offset, vLen).toString("latin1");
    offset += vLen;
    headers.set(k, v);
  }
  return { headers, offset };
}

/** OP_HTTP_REQUEST / OP_HTTP_STREAM_OPEN args: headers first (their own
 *  count-prefixed shape), then `[urlLen: u16][url][methodLen: u8][method]`,
 *  then the body as the rest of the buffer (last field, implicit length —
 *  the same convention `encodeWriteArgs`'s payload uses). */
export function encodeHttpOpenArgs(url, method, body, headers) {
  const urlBytes = Buffer.from(url, "latin1");
  const methodBytes = Buffer.from(method, "latin1");
  const bodyBytes = Buffer.from(body, "latin1");
  const hdrLen = headersByteLength(headers);
  const out = new Uint8Array(hdrLen + 2 + urlBytes.length + 1 + methodBytes.length + bodyBytes.length);
  const view = new DataView(out.buffer);
  let offset = writeHeaders(view, out, 0, headers);
  view.setUint16(offset, urlBytes.length, true);
  offset += 2;
  out.set(urlBytes, offset);
  offset += urlBytes.length;
  out[offset] = methodBytes.length;
  offset += 1;
  out.set(methodBytes, offset);
  offset += methodBytes.length;
  out.set(bodyBytes, offset);
  return out;
}
export function decodeHttpOpenArgs(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const { headers, offset: afterHeaders } = readHeaders(view, bytes, 0);
  let offset = afterHeaders;
  const urlLen = view.getUint16(offset, true);
  offset += 2;
  const url = Buffer.from(bytes.buffer, bytes.byteOffset + offset, urlLen).toString("latin1");
  offset += urlLen;
  const methodLen = bytes[offset];
  offset += 1;
  const method = Buffer.from(bytes.buffer, bytes.byteOffset + offset, methodLen).toString("latin1");
  offset += methodLen;
  const body = Buffer.from(bytes.buffer, bytes.byteOffset + offset, bytes.byteLength - offset);
  return { url, method, body, headers };
}

/** OP_HTTP_REQUEST result: `[status: i32][ok: u8][body bytes (rest)]`. */
export function encodeHttpResponseResult(status, ok, bodyBytes) {
  const out = new Uint8Array(5 + bodyBytes.length);
  new DataView(out.buffer).setInt32(0, status, true);
  out[4] = ok ? 1 : 0;
  out.set(bodyBytes, 5);
  return out;
}
export function decodeHttpResponseResult(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { status: view.getInt32(0, true), ok: bytes[4] !== 0, body: bytes.subarray(5) };
}

/** OP_HTTP_STATUS result: an `i32`. */
export function encodeStatusResult(status) {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setInt32(0, status, true);
  return out;
}
export function decodeStatusResult(bytes) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getInt32(0, true);
}

/** OP_HTTP_DONE result: one byte, 0/1. */
export function encodeBoolResult(b) {
  return new Uint8Array([b ? 1 : 0]);
}
export function decodeBoolResult(bytes) {
  return bytes.length > 0 && bytes[0] !== 0;
}

/** OP_SPAWN args: `[cmdLen: u16][cmd][argCount: u16]`, then that many
 *  `[argLen: u16][arg]` entries. */
export function encodeSpawnArgs(command, args) {
  const cmdBytes = Buffer.from(command, "latin1");
  const argBytesList = args.map((a) => Buffer.from(a, "latin1"));
  let len = 2 + cmdBytes.length + 2;
  for (const a of argBytesList) len += 2 + a.length;
  const out = new Uint8Array(len);
  const view = new DataView(out.buffer);
  let offset = 0;
  view.setUint16(offset, cmdBytes.length, true);
  offset += 2;
  out.set(cmdBytes, offset);
  offset += cmdBytes.length;
  view.setUint16(offset, argBytesList.length, true);
  offset += 2;
  for (const a of argBytesList) {
    view.setUint16(offset, a.length, true);
    offset += 2;
    out.set(a, offset);
    offset += a.length;
  }
  return out;
}
export function decodeSpawnArgs(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 0;
  const cmdLen = view.getUint16(offset, true);
  offset += 2;
  const command = Buffer.from(bytes.buffer, bytes.byteOffset + offset, cmdLen).toString("latin1");
  offset += cmdLen;
  const argCount = view.getUint16(offset, true);
  offset += 2;
  const args = [];
  for (let i = 0; i < argCount; i++) {
    const argLen = view.getUint16(offset, true);
    offset += 2;
    args.push(Buffer.from(bytes.buffer, bytes.byteOffset + offset, argLen).toString("latin1"));
    offset += argLen;
  }
  return { command, args };
}

// Shared wire format between the main thread and the broker worker (spec
// 508). `control` is an `Int32Array(CONTROL_WORDS)` over a SharedArrayBuffer:
// one word each for the state machine, a diagnostic request id, the op
// code, and the argument/response lengths and status. `data` is a second
// SharedArrayBuffer carrying the raw argument bytes on the way in and the
// raw response bytes on the way out -- a request and its response never
// overlap in time (the state machine below forbids it), so both directions
// reuse the same region.
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

/** OP_CONNECT result on success: the socket handle, a `u32`. */
export function encodeConnectResult(handle) {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, handle, true);
  return out;
}
export function decodeConnectResult(bytes) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(0, true);
}

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

// `zlib.*` (spec 039): gzip and raw deflate over byte strings; a stream the
// decompressor rejects yields "" (the native fallback). A compressed stream
// is binary, so it travels in a string as its bytes, one code unit each, in
// either string mode (like `crypto.randomKey`); the text side of each call
// goes through the mode's boundary.
import { Buffer } from "node:buffer";
import nzlib from "node:zlib";
import { toBuffer, fromBuffer } from "./lang.mjs";

const packed = (buf) => buf.toString("latin1");
const unpack = (s) => Buffer.from(s, "latin1");

export function gzipSync(data) {
  try { return packed(nzlib.gzipSync(toBuffer(data))); } catch { return ""; }
}

export function gunzipSync(data) {
  try { return fromBuffer(nzlib.gunzipSync(unpack(data))); } catch { return ""; }
}

/** Raw deflate (no zlib header), as the native runtime emits. */
export function deflateSync(data) {
  try { return packed(nzlib.deflateRawSync(toBuffer(data))); } catch { return ""; }
}

export function inflateSync(data) {
  try { return fromBuffer(nzlib.inflateRawSync(unpack(data))); } catch { return ""; }
}

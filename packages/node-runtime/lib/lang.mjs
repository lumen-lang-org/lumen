// The language-level helpers: the string boundary, integer division, and
// `defer`. Everything else in the package goes through `toBuffer`/`fromBuffer`
// for bytes and `text`/`bytes` for names Node wants as text (paths, env keys,
// command lines), so the representation of a Lumen string is decided here and
// nowhere else.
//
// A Lumen string is a sequence of bytes (spec 505, decision 1): a JavaScript
// string with one code unit per byte, Node's "latin1". Converting on the way
// in is `Buffer.from(s, "latin1")` and on the way out `.toString("latin1")`.
//
// `LUMEN_STRINGS=utf16` is the interim switch spec 503 FR-002 names for
// running hand-written modules whose strings are ordinary JavaScript text
// (nothing has emitted byte literals for them). Spec 505 removes it.

import { Buffer } from "node:buffer";
import { env } from "node:process";

const MODE = env.LUMEN_STRINGS === "utf16" ? "utf16" : "bytes";

/** "bytes" (Lumen byte strings, the default) or "utf16" (plain JavaScript text). */
export const mode = MODE;

/** A Lumen string -> the Buffer holding its bytes. */
export function toBuffer(s) {
  return MODE === "bytes" ? Buffer.from(s, "latin1") : Buffer.from(s, "utf8");
}

/** A Buffer (or Uint8Array) -> the Lumen string holding those bytes. */
export function fromBuffer(buf) {
  const b = Buffer.isBuffer(buf) ? buf : Buffer.from(buf.buffer, buf.byteOffset, buf.byteLength);
  return MODE === "bytes" ? b.toString("latin1") : b.toString("utf8");
}

/** JavaScript text (what Node hands back: a path, an env value, argv) -> a Lumen string. */
export function bytes(text) {
  return MODE === "bytes" ? Buffer.from(text, "utf8").toString("latin1") : text;
}

/** A Lumen string -> JavaScript text (what Node wants for a path, an env key, a command). */
export function text(s) {
  return MODE === "bytes" ? Buffer.from(s, "latin1").toString("utf8") : s;
}

/** Integer division (spec 137): truncates toward zero; a zero divisor throws
 *  the way Zig's safe mode traps (spec 505 documents the RangeError). */
export function divInt(a, b) {
  if (b === 0) throw new RangeError("division by zero");
  return Math.trunc(a / b);
}

/** `using _ = defer(() => cleanup)` (spec 027): the handle `using` disposes. */
export function defer(fn) {
  if (typeof fn !== "function") throw new TypeError("defer expects a function");
  return { dispose: fn, [Symbol.dispose]: fn };
}

/** `e.message` for whatever was thrown: an Error's message, a thrown string
 *  itself, "" for anything else. */
export function errorMessage(e) {
  if (e instanceof Error) return e.message;
  if (typeof e === "string") return e;
  return "";
}

// The names spec 505's emitted code calls.
export { bytes as __bytes, text as __text, divInt as __divInt };

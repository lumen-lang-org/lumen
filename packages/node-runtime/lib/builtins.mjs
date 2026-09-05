// The JavaScript builtins a Lumen program calls with Lumen's own names or
// shapes: `Math.clamp`/`exp2`, the constants that are calls in Lumen
// (`Math.PI()`, `Number.EPSILON()`), `String.contains`/`compare`/`isEmpty`/
// `startsWith`, `Array.isEmpty`, `JSON.parseOpen`, and `Number.parseInt`/
// `parseFloat` returning `null` instead of `NaN` (spec 049). Everything else
// under these namespaces is JavaScript's own.
//
// The exports are overlays over the real builtins (Lumen names as own
// properties, JavaScript's inherited) so `index.mjs` installs nothing.
// `installBuiltins` adds the new names to the real `String`, `Array` and
// `JSON`; `Math` and `Number` carry their constants as non-configurable
// properties, so those two globals are replaced by the overlays (every
// JavaScript name still resolves through the prototype chain, and
// `Number(x)` still converts).
import { bytes, mode } from "./lang.mjs";

const JS = { Math: globalThis.Math, String: globalThis.String, Array: globalThis.Array, Number: globalThis.Number, JSON: globalThis.JSON, Date: globalThis.Date, Promise: globalThis.Promise };

/** A zero-argument call that still reads as its number: `Math.PI()` and
 *  `Math.PI * 2` both work. */
function constant(value) {
  const fn = () => value;
  fn.valueOf = () => value;
  fn.toString = () => String(value);
  fn[Symbol.toPrimitive] = () => value;
  return fn;
}

const MATH_CONSTANTS = ["E", "LN10", "LN2", "LOG10E", "LOG2E", "PI", "SQRT1_2", "SQRT2"];
const NUMBER_CONSTANTS = ["EPSILON", "MAX_SAFE_INTEGER", "MAX_VALUE", "MIN_SAFE_INTEGER", "MIN_VALUE", "NEGATIVE_INFINITY", "NaN", "POSITIVE_INFINITY"];

const WS = new Set([" ", "\t", "\n", "\r"]);

/** `Number.parseInt(s, radix?)`: the longest digit prefix as an `int`, or
 *  `null` when there is none, the radix is out of range, or the value does
 *  not fit 32 bits (the native `__parseInt`). */
export function parseInt(s, radixIn = 10) {
  let i = 0;
  while (i < s.length && WS.has(s[i])) i++;
  let neg = false;
  if (i < s.length && (s[i] === "+" || s[i] === "-")) { neg = s[i] === "-"; i++; }
  let radix = JS.Number(radixIn) | 0;
  if ((radix === 16 || radix === 0) && i + 1 < s.length && s[i] === "0" && (s[i + 1] === "x" || s[i + 1] === "X")) { i += 2; radix = 16; }
  if (radix === 0) radix = 10;
  if (radix < 2 || radix > 36) return null;
  let val = 0;
  let any = false;
  for (; i < s.length; i++) {
    const c = s.charCodeAt(i);
    let d;
    if (c >= 48 && c <= 57) d = c - 48;
    else if (c >= 97 && c <= 122) d = c - 97 + 10;
    else if (c >= 65 && c <= 90) d = c - 65 + 10;
    else d = 255;
    if (d >= radix) break;
    val = val * radix + d;
    any = true;
    if (val > 2147483648) return null;
  }
  if (!any) return null;
  if (neg) val = -val;
  if (val > 2147483647 || val < -2147483648) return null;
  return val;
}

const FLOAT_CHARS = /^[0-9.eE+-]$/;
const FLOAT = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/;

/** `Number.parseFloat(s)`: the longest numeric prefix, or `null`. */
export function parseFloat(s) {
  let i = 0;
  while (i < s.length && WS.has(s[i])) i++;
  const start = i;
  if (i < s.length && (s[i] === "+" || s[i] === "-")) i++;
  while (i < s.length && FLOAT_CHARS.test(s[i])) i++;
  for (let end = i; end > start; end--) {
    const piece = s.slice(start, end);
    if (FLOAT.test(piece)) return JS.Number(piece);
  }
  return null;
}

/** `String.fromCodePoint(cp)`: the code point as Lumen bytes (spec 472). */
export function fromCodePoint(...cps) {
  return bytes(JS.String.fromCodePoint(...cps));
}

export const mathExtras = {
  clamp: (x, lo, hi) => JS.Math.min(JS.Math.max(x, lo), hi),
  exp2: (x) => 2 ** x,
  ...Object.fromEntries(MATH_CONSTANTS.map((k) => [k, constant(JS.Math[k])])),
};

export const stringExtras = {
  contains: (s, sub) => s.includes(sub),
  startsWith: (s, prefix) => s.startsWith(prefix),
  isEmpty: (s) => s.length === 0,
  compare: (a, b) => (a < b ? -1 : a > b ? 1 : 0),
  fromCodePoint: mode === "bytes" ? fromCodePoint : JS.String.fromCodePoint,
};

export const arrayExtras = {
  isEmpty: (a) => a.length === 0,
};

export const numberExtras = {
  parseInt,
  parseFloat,
  ...Object.fromEntries(NUMBER_CONSTANTS.map((k) => [k, constant(JS.Number[k])])),
};

export const jsonExtras = {
  parseOpen: (text) => JS.JSON.parse(text),
};

function overlay(base, extras) {
  const o = Object.create(base);
  for (const [k, v] of Object.entries(extras)) Object.defineProperty(o, k, { value: v, configurable: true, writable: true, enumerable: true });
  return o;
}

/** `Number` as a callable overlay: converts like JavaScript's, inherits its
 *  statics, and carries Lumen's `parseInt`/`parseFloat` and constants. */
function numberOverlay() {
  const fn = function Number(value) { return arguments.length === 0 ? JS.Number() : JS.Number(value); };
  Object.setPrototypeOf(fn, JS.Number);
  Object.defineProperty(fn, "prototype", { value: JS.Number.prototype, writable: false, configurable: false });
  for (const [k, v] of Object.entries(numberExtras)) Object.defineProperty(fn, k, { value: v, configurable: true, writable: true, enumerable: true });
  return fn;
}

export const Math = overlay(JS.Math, mathExtras);
export const String = overlay(JS.String, stringExtras);
export const Array = overlay(JS.Array, arrayExtras);
export const Number = numberOverlay();
export const JSON = overlay(JS.JSON, jsonExtras);
export const Date = JS.Date;
export const Promise = JS.Promise;

/** Writes the Lumen names onto the real builtins. Idempotent. */
export function installBuiltins(g = globalThis) {
  const put = (target, extras) => {
    for (const [k, v] of Object.entries(extras)) Object.defineProperty(target, k, { value: v, configurable: true, writable: true, enumerable: false });
  };
  Object.defineProperty(g, "Math", { value: Math, configurable: true, writable: true, enumerable: false });
  Object.defineProperty(g, "Number", { value: Number, configurable: true, writable: true, enumerable: false });
  put(g.String, stringExtras);
  put(g.Array, arrayExtras);
  put(g.JSON, jsonExtras);
}

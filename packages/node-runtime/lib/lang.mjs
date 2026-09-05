// The language-level helpers: the string boundary, the string methods whose
// JavaScript namesakes compute something else on a byte string, integer
// division, and `defer`. Everything else in the package goes through
// `toBuffer`/`fromBuffer` for bytes and `text`/`bytes` for names Node wants
// as text (paths, env keys, command lines), so the representation of a Lumen
// string is decided here and nowhere else.
//
// A Lumen string is a sequence of bytes (spec 505, decision 1): a JavaScript
// string with one code unit per byte, Node's "latin1". Converting on the way
// in is `Buffer.from(s, "latin1")` and on the way out `.toString("latin1")`,
// never `utf8`. Generated code (spec 504) spells its literals as those bytes
// (`"\xC3\xA9"` for "é"), so `length`, `[i]`, `slice`, `indexOf`, `+`, `==`
// and `<` are JavaScript's own operations; the methods below are the ones
// that are not, and the emitter routes them here as `__lang.<name>`.

import { Buffer } from "node:buffer";

/** A Lumen string -> the Buffer holding its bytes. */
export function toBuffer(s) {
  return Buffer.from(s, "latin1");
}

/** A Buffer (or Uint8Array) -> the Lumen string holding those bytes. */
export function fromBuffer(buf) {
  const b = Buffer.isBuffer(buf) ? buf : Buffer.from(buf.buffer, buf.byteOffset, buf.byteLength);
  return b.toString("latin1");
}

/** JavaScript text (what Node hands back: a path, an env value, argv) -> a Lumen string. */
export function bytes(text) {
  return Buffer.from(text, "utf8").toString("latin1");
}

/** A Lumen string -> JavaScript text (what Node wants for a path, an env key, a command). */
export function text(s) {
  return Buffer.from(s, "latin1").toString("utf8");
}

// ---------------------------------------------------------------------------
// String methods with byte semantics (spec 505 FR-001). Each takes the
// receiver first and answers what the native runtime answers
// (`lumen_emit_array_string.zig` `emitStringMethod`).

/** `s.charCodeAt(i)` / `s.codePointAt(i)`: the byte at `i`, or -1 past either
 *  end (specs 101, 119) where JavaScript answers NaN. */
export function charCodeAt(s, i) {
  const c = s.charCodeAt(i);
  return Number.isNaN(c) ? -1 : c;
}

/** ASCII-only case mapping (spec 063): a byte above 0x7f is part of a UTF-8
 *  sequence, not a character JavaScript's `toUpperCase` may rewrite. */
export function toUpperCase(s) {
  return s.replace(/[a-z]+/g, (run) => run.toUpperCase());
}

export function toLowerCase(s) {
  return s.replace(/[A-Z]+/g, (run) => run.toLowerCase());
}

// Space, tab, CR, LF: what the native `trim` strips. JavaScript's also strips
// 0xA0 and 0x85, which are trailing bytes of "à" and "…".
const LEADING_WS = /^[ \t\r\n]+/;
const TRAILING_WS = /[ \t\r\n]+$/;

export function trim(s) {
  return s.replace(LEADING_WS, "").replace(TRAILING_WS, "");
}

export function trimStart(s) {
  return s.replace(LEADING_WS, "");
}

export function trimEnd(s) {
  return s.replace(TRAILING_WS, "");
}

/** Byte order, -1/0/1 (spec 109): `<` on two byte strings compares code
 *  units, which are the bytes. */
export function localeCompare(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** A negative count is an empty string, not a RangeError. */
export function repeat(s, n) {
  return n > 0 ? s.repeat(n) : "";
}

/** `s.replace(from, to)` with a string pattern: the first occurrence, the
 *  replacement taken literally (`$&` is two characters), an empty pattern
 *  matching nothing (spec 063). */
export function replace(s, from, to) {
  if (from.length === 0) return s;
  const i = s.indexOf(from);
  return i < 0 ? s : s.slice(0, i) + to + s.slice(i + from.length);
}

export function replaceAll(s, from, to) {
  if (from.length === 0) return s;
  return s.split(from).join(to);
}

// ---------------------------------------------------------------------------
// JSON (spec 505, decision 1). A JSON document is itself bytes, so
// `stringify` over byte strings is JavaScript's own: every code unit of a
// byte string is copied into the output verbatim, and the escapes it adds
// are ASCII. `parse` is not: a `\u00e9` escape in the document decodes to
// one code unit, which must become the two bytes of "é", while a raw byte
// above 0x7f must stay one code unit. So the document is decoded to text,
// parsed, and every string in the result -- keys included -- re-encoded.

const jsParse = JSON.parse;

function encodeStrings(v) {
  if (typeof v === "string") return bytes(v);
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(encodeStrings);
  const out = {};
  for (const [k, x] of Object.entries(v)) out[bytes(k)] = encodeStrings(x);
  return out;
}

/** What a scalar shape wants, in the words the native parser uses (483). */
const WANTS = { string: "a string", int: "a whole number", number: "a number", bool: "a true or false" };

/** Whether `v` is a value of the scalar shape `kind`. */
function isScalar(kind, v) {
  switch (kind) {
    case "string": return typeof v === "string";
    case "int": return typeof v === "number" && Number.isInteger(v);
    case "number": return typeof v === "number";
    case "bool": return typeof v === "boolean";
    default: return true;
  }
}

/** Why `v` is not a value of `shape` -- the native parser's error name
 *  (`MissingField`, `UnknownField`, `UnexpectedToken`) -- or null. An
 *  optional shape admits null. `open` lets a record carry members its type
 *  does not declare (spec 500). */
function mismatch(v, shape, open) {
  if (typeof shape === "string") return isScalar(shape, v) ? null : "UnexpectedToken";
  if (shape.o !== undefined) return v === null || v === undefined ? null : mismatch(v, shape.o, open);
  if (shape.a !== undefined) {
    if (!Array.isArray(v)) return "UnexpectedToken";
    for (const x of v) { const why = mismatch(x, shape.a, open); if (why) return why; }
    return null;
  }
  if (v === null || typeof v !== "object" || Array.isArray(v)) return "UnexpectedToken";
  for (const [name, field] of Object.entries(shape.f)) {
    if (!(name in v)) { if (isOptional(field)) continue; return "MissingField"; }
    const why = mismatch(v[name], field, open);
    if (why) return why;
  }
  if (!open) for (const k of Object.keys(v)) if (!(k in shape.f)) return "UnknownField";
  return null;
}

function isOptional(shape) {
  return typeof shape === "object" && shape.o !== undefined;
}

/** The native parser's account of a refused document, which looks at the
 *  top-level record only: a required field not sent, then a member the
 *  type does not declare, then a scalar field of the wrong kind (483). Any
 *  other refusal is `invalid JSON (<error name>)`. */
function blame(v, shape, open, why) {
  if (typeof shape === "object" && shape.f !== undefined && v !== null && typeof v === "object" && !Array.isArray(v)) {
    for (const [name, field] of Object.entries(shape.f)) {
      if (!(name in v) && !isOptional(field)) return "JSON.parse: the field \"" + name + "\" is required and was not sent";
    }
    if (!open) for (const k of Object.keys(v)) if (!(k in shape.f)) return "JSON.parse: the field \"" + k + "\" is not one this accepts";
    for (const [name, field] of Object.entries(shape.f)) {
      const kind = isOptional(field) ? field.o : field;
      if (typeof kind !== "string" || !(kind in WANTS)) continue;
      if (name in v && v[name] !== null && !isScalar(kind, v[name])) return "JSON.parse: the field \"" + name + "\" wants " + WANTS[kind];
    }
  }
  return "JSON.parse: invalid JSON (" + why + ")";
}

/** The argument `JSON.parse<Class>` constructs an instance with. A `#private`
 *  field exists on an object only when the class's field initializers ran,
 *  and JavaScript runs them during construction and nowhere else, so a
 *  revived instance is `new C(REVIVE)`: the emitter (spec 504) opens every
 *  constructor with `if (arguments[0] === __lang.REVIVE) return;`, so the
 *  fields get their declared defaults and the constructor body never runs
 *  (spec 456). A derived class forwards the sentinel to `super` first. */
export const REVIVE = Symbol.for("lumen.revive");

/** `v`, checked, as the program's type holds it: a class instance gets its
 *  prototype and field defaults without its constructor body running
 *  (spec 456; `REVIVE`), and an optional field not sent is null, as it is
 *  natively. */
function revive(v, shape) {
  if (typeof shape === "string" || v === null || v === undefined) return v;
  if (shape.o !== undefined) return revive(v, shape.o);
  if (shape.a !== undefined) return v.map((x) => revive(x, shape.a));
  const out = shape.c !== undefined ? new shape.c(REVIVE) : {};
  for (const [name, field] of Object.entries(shape.f)) out[name] = name in v ? revive(v[name], field) : null;
  for (const k of Object.keys(v)) if (!(k in shape.f)) out[k] = v[k];
  return out;
}

/** `JSON.parse<T>(s)` over a byte string, answering byte strings: `shape`
 *  is T as the emitter describes it (`"string"`, `{f: {...}}`, `{a: ...}`,
 *  `{o: ...}`, `{c: Class, f: ...}`, `"any"`); without one the document is
 *  taken as it is. A refused document throws with the message the native
 *  parser gives; malformed JSON is `invalid JSON (SyntaxError)`. */
export function jsonParse(s, shape, open = false) {
  let v;
  try {
    v = jsParse(text(s));
  } catch (e) {
    throw new Error("JSON.parse: invalid JSON (SyntaxError)");
  }
  v = encodeStrings(v);
  if (shape === undefined) return v;
  const why = mismatch(v, shape, open);
  if (why) throw new Error(blame(v, shape, open, why));
  return revive(v, shape);
}

// ---------------------------------------------------------------------------
// Numbers as text (spec 505 decision 2). The native runtime prints a
// `number` with Zig's `{d}`: the shortest digits that read back as the same
// double, every one of them written out -- `1e21` is
// "1000000000000000000000" and `1e-7` is "0.0000001" -- and `nan`, `inf`,
// `-inf` for the non-finite values. JavaScript's `String(x)` agrees except
// that it switches to `1e+21`/`1e-7` notation past 21 digits or 6 leading
// zeros, which is undone here. An integer prints the same either way.

/** A number as the native runtime prints it. */
export function fmt(x) {
  if (Number.isNaN(x)) return "nan";
  if (x === Infinity) return "inf";
  if (x === -Infinity) return "-inf";
  if (Object.is(x, -0)) return "-0";
  const s = String(x);
  const e = s.indexOf("e");
  if (e < 0) return s;
  const exp = Number(s.slice(e + 1));
  let mantissa = s.slice(0, e);
  const neg = mantissa.startsWith("-");
  if (neg) mantissa = mantissa.slice(1);
  const dot = mantissa.indexOf(".");
  const digits = dot < 0 ? mantissa : mantissa.slice(0, dot) + mantissa.slice(dot + 1);
  // Where the decimal point lands in `digits` once the exponent is applied.
  const point = (dot < 0 ? mantissa.length : dot) + exp;
  let out;
  if (point <= 0) out = "0." + "0".repeat(-point) + digits;
  else if (point >= digits.length) out = digits + "0".repeat(point - digits.length);
  else out = digits.slice(0, point) + "." + digits.slice(point);
  return neg ? "-" + out : out;
}

// ---------------------------------------------------------------------------
// Printing. `console.log` hands its arguments to Node's formatter, which
// writes text: a byte string is decoded first, wherever it sits (an array
// element, a record field, a Map key), so the bytes reach the terminal as
// the UTF-8 they are, and a number is formatted as the native runtime
// formats one.

/** One `console.log` argument: a number as the native runtime formats it,
 *  anything else with its byte strings decoded. */
export function printArg(v) {
  return typeof v === "number" ? fmt(v) : printable(v);
}

/** A value with every byte string in it decoded to text, for printing. A
 *  number inside a container stays a number, so the formatter still shows
 *  it unquoted. */
export function printable(v) {
  if (typeof v === "string") return text(v);
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(printable);
  if (v instanceof Map) return new Map(Array.from(v, ([k, x]) => [printable(k), printable(x)]));
  if (v instanceof Set) return new Set(Array.from(v, printable));
  if (ArrayBuffer.isView(v) || v instanceof Error || v instanceof Promise || v instanceof Date) return v;
  // A record or a class instance: the same shape (and prototype, so a class
  // still prints under its name) with its fields decoded.
  const out = Object.create(Object.getPrototypeOf(v));
  for (const [k, x] of Object.entries(v)) out[k] = printable(x);
  return out;
}

// ---------------------------------------------------------------------------
// Numbers and control flow.

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

// The names spec 505's emitted code calls, beside the string methods above.
export { bytes as __bytes, text as __text, divInt as __divInt, fmt as __fmt };

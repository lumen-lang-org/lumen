# Spec 056: Buffer

## Goal

A real `Buffer` (byte-array) type. The most-referenced missing Node type in
this session's stdlib work, and the silent blocker behind every planned
crypto-bytes/binary-streams gap: `crypto.*` currently returns hex/base64
*strings* only (spec 035), and `ReadableStream`/`WritableStream` (spec 046)
carry `string` chunks only, both because there was no byte-array type to hand
back instead. This spec adds the type itself and its own construction/
inspection surface. It deliberately does **not** wire `Buffer` into `crypto`,
streams, or `JSON` in this pass -- see "Not planned."

## Why a new `Type` variant, not `string`

Lumen's `string` is already `[]const u8` -- raw bytes, not validated UTF-8
(documented existing behavior). It might seem like `Buffer` could just *be*
`string` with different method names. Rejected: a real, distinct type is
required to catch the exact bug class this exists to prevent -- passing raw
binary data where a text API expects UTF-8-ish text (or vice versa) -- as a
*compile-time* type error, not a silent runtime mismatch. `Map`/`Set`/
`ReadableStream` all made the same call for the same reason (see spec
020/046). Verified concretely in this pass: `let s: string = Buffer.from("x")`
and `let b: Buffer = "x"` both now fail with `E_TYPE_MISMATCH` at compile
time -- proof this is a distinct type, not `string` wearing a different name.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `Buffer.from(s)` | `string -> Buffer` | raw bytes of `s`, no decoding |
| `Buffer.from(s, encoding)` | `(string, string) -> Buffer` | decodes `s` under `"utf8"` \| `"hex"` \| `"base64"`; an unrecognized encoding string falls back to `"utf8"` (raw bytes), matching this codebase's existing "fallback, don't crash" convention rather than a runtime throw |
| `Buffer.alloc(n)` | `int -> Buffer` | `n` zeroed bytes; a negative `n` clamps to 0 |

| Method | Type | Notes |
| --- | --- | --- |
| `Buffer.length` | `() -> int` (field syntax, no parens) | byte count |
| `Buffer.toString(encoding)` | `string -> string` | `"utf8"` (raw passthrough) \| `"hex"` \| `"base64"`; unrecognized falls back to `"utf8"` |
| `Buffer.at(i)` | `int -> int` | the byte value at index `i` (0-255); out of range (including negative) returns `0` |
| `Buffer.slice(start, end)` | `(int, int) -> Buffer` | a new `Buffer` over `[start, end)`, clamped into range the same way `string.slice` behaves |
| `Buffer.equals(other)` | `Buffer -> bool` | byte-for-byte comparison |

## Design notes

- **Architecture**: `Buffer` is a new bare `Type` variant (`.buffer_type`,
  no payload -- every buffer is `[]const u8`-backed, there is no generic
  element type to parameterize), following the exact `ReadableStream`/
  `WritableStream` precedent from spec 046: a dedicated Zig struct
  (`LumenBuffer`, wrapping `data: []const u8`), heap-allocated via `__sa()`
  (the stable arena every other container type already uses), constructed
  through a `Buffer` static namespace (`Buffer.from`/`Buffer.alloc`, added to
  `isStdNamespace`/`bufferCallType`/`staticCallType`'s dispatch, mirroring
  `fsCallType`) rather than a `new` expression -- consistent with
  `fs.createReadStream` doing the same for the same reason (always
  constructed via a function, never usefully "empty" without one).
- **`typeFromAnnotation` resolves the literal name `"Buffer"` directly to
  `.buffer_type`, unlike `ReadableStream`/`WritableStream`, which don't
  resolve at all today**: checked this concretely before writing this
  spec, not assumed. `let r: ReadableStream = fs.createReadStream(p)` was
  tried against the current compiler and produces `E_TYPE_MISMATCH` --
  `typeFromAnnotation` has no `"ReadableStream"`/`"WritableStream"` case, so
  the annotation falls through to `types.fromAnnotation`, which returns a
  plain `.named` type carrying the annotation string; that never equals the
  `.readable_stream_type` the RHS actually produces. Every existing example
  and conformance test for streams only uses inferred `let` (no explicit
  annotation), so this gap was never exercised. `Buffer` is given an
  explicit case in `typeFromAnnotation` (`"Buffer" -> .buffer_type`) so
  `let b: Buffer = Buffer.from("x")` works, rather than silently
  reproducing the same unexercised gap in a brand new type.
- **`.length` as field syntax (no parens), following `Map`/`Set`'s `.size`
  precedent, not array/string's `.length`**: checked both existing
  precedents before picking one. `string`/array `.length` lowers straight to
  Zig's own slice `.len` field (`fa.builtin == .length` emits `obj.len`)
  because both are raw slices already. `Map`/`Set` `.size` instead emits a
  *method call* on the heap-pointer container (`fa.builtin ==
  .container_size` emits `obj.size()`) because the size isn't a raw slice
  field on the wrapper struct. `Buffer` is heap-pointer-wrapped the same way
  `Map`/`Set` are (`*LumenBuffer`, not a raw `[]const u8` at the Lumen type
  level), so it follows the `Map`/`Set` shape: a new `FieldBuiltin.
  buffer_length` field-syntax builtin that emits `obj.length()`, a real Zig
  method on `LumenBuffer` (`fn length(self: *LumenBuffer) i32`), not
  `obj.data.len` reaching through the wrapper directly. Node's own
  `Buffer.length` is a plain property, not a call -- the field syntax here
  matches Node's surface even though the emitted Zig is a method call
  underneath, the same way `Map.size`'s field syntax hides its own
  `.size()` call.
- **`.at(i)` only, no `buf[i]` index syntax**: the language's `[i]` index
  checker is array-specific (`i32_array`/`string_array`/etc., not
  extensible to an arbitrary container type without touching indexing's own
  type-narrowing logic, out of scope for this pass). Documented as a
  deliberate gap, not attempted.
- **Hex/base64 verified against this Zig version's actual std source, not
  assumed from another language's API shape**: `std.fmt.allocPrint(alloc,
  "{x}", .{bytes})` (a `[]const u8`'s own `{x}` format specifier, not
  `std.fmt.fmtSliceHexLower`, which does not exist in this Zig version) for
  hex-encode; `std.fmt.hexToBytes(out_buf, hex_str)` for hex-decode (errors
  on odd length or non-hex characters -- both caught, falling back to an
  empty `Buffer`, not a crash); `std.base64.standard.Encoder.calcSize(len)`
  + `.encode(buf, bytes)` for base64-encode; `std.base64.standard.Decoder.
  calcSizeForSlice(str)` + `.decode(buf, str)` for base64-decode (both can
  error on invalid input -- `error.InvalidPadding`/`error.InvalidCharacter`
  confirmed by actually calling them with bad input in a throwaway `zig run`
  script before wiring this into the compiler, not assumed from the
  function names). All four round-tripped exactly against the known vector
  `"hi"` <-> hex `"6869"` <-> base64 `"aGk="` in that same throwaway script
  before any compiler code was written.
- **`Buffer.from(s, encoding)`'s unrecognized-encoding fallback is
  "treat as utf8/raw", not a thrown error**: matches this codebase's
  existing convention everywhere an unopenable file, a missing key, or an
  out-of-range index degrades to a documented fallback value rather than a
  runtime panic (see `ReadableStream.read()` on a missing file, `.at()` out
  of range here). Node itself throws `ERR_UNKNOWN_ENCODING` for real; this
  is a deliberate, documented simplification for v1, not an attempt to
  match Node's error behavior.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| `crypto.*` returning `Buffer` instead of hex/base64 strings | a real audit of every existing `crypto` call site and its current string-returning contract (spec 035) -- a breaking change to an existing API, deliberately not bundled into the pass that first introduces the type it would return |
| `ReadableStream`/`WritableStream` chunks as `Buffer` instead of `string` | same reasoning: spec 046 already shipped and is exercised as `string`-chunked; switching its chunk type is a separate, real migration |
| `JSON` (de)serialization of `Buffer` | no existing convention in this codebase for how a byte array should round-trip through JSON (Node uses `{"type":"Buffer","data":[...]}`); not decided here |
| `Buffer.concat([...])` | needs a decision on how a Lumen array of `Buffer` values is spelled (`Buffer[]` -- untested combination of a new bare type with array-of syntax) before it's worth building; a real stretch goal, not forgotten |
| `buf[i]` index syntax | the indexing checker is array-type-specific; `.at(i)` covers the same need today |

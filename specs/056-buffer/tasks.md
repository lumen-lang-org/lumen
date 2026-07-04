# Tasks: Buffer

## Phase 1

- [x] T1 Added `.buffer_type` to the `Type` union in `lumen_types.zig` (no
  payload). Used the exhaustive-switch compile errors to find every arm
  needing a case: `mangle` (`"buffer"`), `same`, `toAnnotation`
  (`"Buffer"`), `zigName` (`"*LumenBuffer"`). Added `isBuffer(t)`.
- [x] T2 `typeFromAnnotation` (`lumen_check.zig`): added an explicit
  `"Buffer" -> .buffer_type` case. Checked concretely first that
  `ReadableStream`/`WritableStream` annotations do *not* resolve this way
  today (`let r: ReadableStream = fs.createReadStream(p)` fails
  `E_TYPE_MISMATCH` against the pre-Buffer compiler) -- Buffer gets the
  case streams are missing, not a copy of streams' current gap.
- [x] T3 `Buffer` static namespace: added to `isStdNamespace`
  (`lumen_parser.zig`), `bufferCallType` (`lumen_check_stdlib.zig`,
  handling `from(s)`, `from(s, encoding)`, `alloc(n)`), a dispatch line in
  `staticCallType`, and the `pub const bufferCallType = ...` alias in
  `lumen_check.zig`'s `Checker` struct.
- [x] T4 `bufferMethod` (`lumen_check_stdlib.zig`, mirroring
  `readableStreamMethod`'s structure): `toString(encoding)`, `at(i)`,
  `slice(start, end)`, `equals(other)`. Dispatch line in
  `lumen_check_expr.zig`'s method-call resolution (`types.isBuffer(obj_type)`
  before the class-type fallback).
- [x] T5 `.length` as field syntax (no parens): added
  `FieldBuiltin.buffer_length` (`lumen_ast.zig`), a check in
  `lumen_check_expr.zig`'s field-type resolution (`types.isBuffer(obj_type)
  and eql(field.name, "length")`, following the `Map`/`Set` `.size` ->
  `container_size` precedent, not the raw-slice `string`/array `.length`
  precedent -- `Buffer` is heap-pointer-wrapped like `Map`/`Set`, not a raw
  slice at the Lumen type level), and an emit branch in `lumen_emit.zig`
  (`obj.length()`).
- [x] T6 `program.needs_buffer` flag (`lumen_ast.zig`), an emit branch for
  `Buffer.from`/`Buffer.alloc` construction in `lumen_emit.zig`'s
  static-call chain, and the flag-gated `LumenBuffer` runtime block in
  `lumen_compiler.zig` (`__bufferFromUtf8`, `__bufferFromEncoded`,
  `__bufferAlloc`, plus `LumenBuffer.length/at/slice/equals/toString`).
  De-risked the exact hex/base64 std APIs in a standalone `zig run` script
  before wiring them into the compiler (see spec.md's design notes) --
  `std.fmt.fmtSliceHexLower` does not exist in this Zig version, a `{x}`
  format specifier on the `[]const u8` itself does the job instead.
- [x] T7 Verified with a real, run (not just compiled) `.ts` program:
  - `Buffer.from("hi").toString("hex")` == `"6869"`, and
    `Buffer.from("6869", "hex").toString("utf8")` == `"hi"` -- round-trip
    both directions against a known vector.
  - `Buffer.from("hi").toString("base64")` == `"aGk="`, and
    `Buffer.from("aGk=", "base64").toString("utf8")` == `"hi"`.
  - `Buffer.alloc(5).length` == `5`, and `Buffer.alloc(5).at(0)` == `0`
    (zeroed).
  - `Buffer.alloc(3).at(10)` == `0` (out-of-range fallback, not a crash).
  - `Buffer.from("hello").slice(1, 3).toString("utf8")` == `"el"`.
  - `Buffer.from("abc").equals(Buffer.from("abc"))` == `true`;
    `Buffer.from("abc").equals(Buffer.from("abd"))` == `false`.
  - `let s: string = Buffer.from("x");` and `let b: Buffer = "x";` both
    fail `E_TYPE_MISMATCH` at compile time -- confirms `Buffer` is a real,
    distinct type, not `string` under another name.
- [x] T8 `zig build test` passes. One full, clean, non-concurrent
  `zig build conformance` run: 206 passed, 0 failed.
- [x] T9 Updated `website/stdlib.html`: quick-jump nav link, a new
  `Buffer` `<h4>` section with per-function `<div class="api">` blocks
  (stability pills, the encoding-fallback and no-index-syntax deviations
  called out honestly), validated afterward with Python's `html.parser`.
- [x] T10 One focused commit (local only; no push, no playground deploy).

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: `crypto`/streams/`JSON` integration
(each a real, separate migration of an already-shipped API's contract),
`Buffer.concat` (needs a `Buffer[]` array-of-new-bare-type decision first),
`buf[i]` index syntax (the array-specific indexing checker would need
generalizing).

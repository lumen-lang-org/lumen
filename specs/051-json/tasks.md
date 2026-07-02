# Tasks: JSON.stringify / JSON.parse<T>

## Phase 1

- [x] T1 De-risk the core assumption before writing any compiler code:
  standalone Zig program confirming `std.json.Stringify.valueAlloc` and
  `std.json.parseFromSlice` both work automatically on an arbitrary struct
  with no custom `jsonStringify`/`jsonParse` hooks. (Done: see spec.md,
  both directions confirmed with a real compiled program.)
- [x] T2 Add "JSON" to `isStdNamespace` (`lumen_parser.zig`).
- [x] T3 `JSON.stringify(value)` -- checker branch (`jsonCallType` in
  `lumen_check_stdlib.zig`, no type args needed, T inferred from the
  argument), emit branch, runtime wrapper in `lumen_compiler.zig`.
- [x] T4 `JSON.parse<T>(text)` -- the harder one. Add `type_args:
  [][]const u8 = &.{}` to `StaticCall` (`lumen_ast.zig`). Parse an
  optional `<T>` before the `(` at the one `static_call` parse site
  (`lumen_parser_expr.zig`), mirroring the existing free-function
  `isCmp("<") and looksLikeTypeArgs()` -> `parseTypeArgs()` pattern
  exactly. Checker branch resolves the named type argument to a concrete
  `types.Type`, rejects `Map`/`Set`/tuple/unresolvable type arguments with
  a clear diagnostic. Emit branch needs the argument's real Zig type name
  (`types.zigName`) to call `std.json.parseFromSlice(<Name>, ...)`.
- [x] T5 Verify against real programs, not just "it compiles": round-trip
  a record type through `stringify` then `parse<T>` and confirm the
  result matches field-by-field; stringify a primitive (`string`/`int`/
  `bool`) directly; parse malformed JSON and confirm the zeroed fallback
  (empty string fields, 0 ints, false bools) rather than a crash; parse
  JSON with a field of the wrong type and confirm the same graceful
  fallback.
- [x] T6 Confirm `--wasm` behavior (this doesn't touch async/threads/
  sockets, so it should compile and work identically there -- verify
  directly with wasmtime rather than assuming).
- [x] T7 `zig build test` passes. Full, clean, non-concurrent
  `zig build conformance` run.
- [x] T8 Update `website/stdlib.html`: new `JSON` section (quick-jump +
  per-function blocks), remove/replace the existing `<p class="note">`
  in the Planned section that says JSON isn't supported yet and
  `JSON.parse<T>` "arrives later."
- [x] T9 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: `Map`/`Set`/tuple support in
`stringify`/`parse<T>`, a dynamic/`any`-typed `JSON.parse()`, pretty-print
options, custom per-field naming.

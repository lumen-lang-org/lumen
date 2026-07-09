# Spec 063 tasks

- [x] T001 — Check side: add `padEnd`/`replaceAll` (2 args, `string`) and
  `trimStart`/`trimEnd` (0 args) to `stringMethod` specs in
  `src/lumen_check_stdlib.zig`; add `String.fromCharCode` (1 int arg -> string)
  to `stringCallType`.
- [x] T002 — Emit side: add `padEnd` (mirror `padStart`, append receiver first),
  `trimStart`/`trimEnd` (`std.mem.trimStart`/`trimEnd`), and `replaceAll`
  (loop `indexOf` over the tail) to `src/lumen_emit_array_string.zig`.
- [x] T003 — Emit side: lower `String.fromCharCode(code)` to a labeled block that
  allocates one byte `= (code) & 0xFF` in `src/lumen_emit.zig`.
- [x] T004 — Docs: list the new methods in `website/stdlib.html`.
- [x] T005 — Verify: `zig build`, `zig build test`, and a native program
  exercising every method plus its error cases.

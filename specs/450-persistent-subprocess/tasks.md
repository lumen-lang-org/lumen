# Tasks — Spec 450

- [x] `spec.md` / `tasks.md` written (problem, surface, scope, success criteria).
- [x] Type system: add `process_type` variant + arms (mangle/same/toAnnotation/
      tsName/zigName/fromAnnotation) and `isProcess` predicate in `lumen_types.zig`.
- [x] AST flag: `needs_child_process_spawn` in `lumen_ast.zig`.
- [x] Producer: `spawn` arm in `childProcessCallType` (`lumen_check_stdlib_os.zig`).
- [x] Method validator: `childProcessMethod` in `lumen_check_methods.zig`;
      alias in `lumen_check.zig`.
- [x] Method dispatch: `isProcess` arm in `lumen_check_expr.zig`.
- [x] Static-call emit: `__spawn(__io, __alloc, ...)` in `lumen_emit_static.zig`.
- [x] Runtime: `LumenChildProcess` + `__spawn`, gated on
      `needs_child_process_spawn`, in `lumen_runtime_os.zig`.
- [x] Examples: `roundtrip` (test-run), `roundtrip-run` (compile-run), invalid
      diagnostics cases.
- [x] Conformance manifest + `build.zig` wiring.
- [x] Regenerate `docs/CODEMAP.md`.
- [x] Gates: `zig build`, `zig build test`, `zig build conformance`.

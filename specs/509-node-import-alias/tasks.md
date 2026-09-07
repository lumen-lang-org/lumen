# Tasks: 509 import alias on the node target

**Input**: spec.md's "What's confirmed" section. Not investigated further
this session — the fix needs tracing how the checker resolves an aliased
cross-module reference in the first place (spec.md names where to start).

- [ ] T001 Trace how the checker resolves `import { x as y }`: what marks a
  `var_ref` to `y` as referring to another module's `x`, and whether that
  survives to where `emitProgram` (`lumen_emit_js.zig`) computes
  `refs`/`exports`/import statements.
- [ ] T002 Fix `emitImport`/the refs computation to preserve the alias in
  the generated import statement (or otherwise avoid the collision) when
  one was written in the source.
- [ ] T003 Add a `node-run` case for `examples/valid/import_alias.ts`
  (currently only `compile-run` — native already works) once the node
  target prints `root\nroot` too; register the manifest in `build.zig`.
- [ ] T004 Confirm the single-reference-only case (no colliding local
  anywhere) still emits the same or an equally correct form — don't
  regress the mangled-name path that already works.
- [ ] T005 `zig build test`/`zig build conformance` green. Re-verify
  against Joule's actual `code.ts`: `lumen compile --target node
  src/code.ts` then run past `runDaemonJoule` without this crash
  (joule-sh/code, `src/terminal/attach.ts`).

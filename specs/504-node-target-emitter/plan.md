# Plan: 504 JavaScript emitter

## Technical context

- Zig 0.16, the existing pipeline: `compileToZigWithOptions`
  (`src/lumen_compiler.zig:265`) parses, checks (`check.checkProgram`), runs
  the `lumen_opt` passes, then calls `lumen_emit.emitProgram`. The new
  backend is a sibling of the last call: `lumen_emit_js.emitProgram`, fed the
  same `ast.Program` after the same passes.
- Driver: `src/lumen.zig:2974 compileFile` decides what to do with the
  generated text (`:3097` writes `.lumen-<base>.zig`, `:3140` builds). A
  `node` target writes the module directory instead and does not invoke
  `zig build-exe`.
- Multi-file programs: the front end inlines imported modules into one
  `Program` with module-scoped names (`moduleScopedName`,
  `src/lumen_emit.zig:1631`, `MODULE_SELF :1589`). Find where the module
  boundary is still visible (each `Stmt` carries its origin via
  `line_map`/`LineOrigin`, `src/lumen_diag.zig:11`) — the JS emitter needs
  it to split output per module. If the boundary is gone by emit time, keep
  a `module_id` on statements during inlining (small front-end change,
  benefits diagnostics too).
- Type-only imports: the checker resolves each import binding
  (`lumen_check_stmt.zig:43 declareExtern`, spec 451); mark bindings that
  resolved to a type so the emitter drops them.

## Files

```
src/lumen_emit_js.zig           # emitProgram, module writer, imports/exports
src/lumen_emit_js_expr.zig      # expressions (the switch mirrors lumen_emit.zig:240 emitExpr)
src/lumen_emit_js_stmt.zig      # statements (mirrors lumen_emit_stmt.zig:158)
src/lumen_emit_js_class.zig     # classes, enums, accessors
src/lumen_emit_js_stdlib.zig    # static calls: which namespace call needs a wrapper vs identity
tools/lumen_conformance.zig     # node-run phase
tools/emit_snapshot.sh          # native emit no-regression diff
```

## Approach

1. **Skeleton first, gate first.** Add `--target node` parsing
   (`src/lumen.zig:3628` loop), a `Target.node` in `CompileOptions`
   (`src/lumen_emit.zig:1447`), the output-directory writer, and the
   `node-run` conformance phase, with an emitter that handles only
   `console.log` of literals. Register manifest; green. Everything after is
   filling the `switch` arms, and every arm lands with a corpus program.
2. **Expressions and statements** in the order the corpus needs them: walk
   `specs/*/examples/valid` numerically; each newly passing program is added
   to `corpus.txt`. The AST is TypeScript-shaped, so most arms print the
   source form back; the Zig emitter's arm is the checklist of what the node
   carries (temporaries, `checked_operand_type`, narrowing casts) and what
   to ignore.
3. **Modules**: per-module files, import rewriting, type-only elision,
   https modules under `modules/https/`.
4. **Classes, enums, `using`/`defer`, `JSON.parse<T>` validators**,
   `embed`.
5. **Stdlib static calls**: for each namespace call the checker accepts,
   decide identity (`Math.floor`) vs runtime helper (`process.platform()`
   is identity because 503 shaped the runtime to Lumen; string-taking calls
   need 505's boundary helpers). Table lives in `lumen_emit_js_stdlib.zig`
   and is checked against 503's `names.json` by a Zig test.
6. `lumen run --target node`, `--out`, `--runtime`, `E_TARGET_UNSUPPORTED`.

## Verification

- `zig build test`; `zig build conformance` (native unchanged);
  `tools/emit_snapshot.sh` diff empty; `node-run` phase for every manifest
  whose corpus entries are eligible (the runner reads the same manifests: a
  `compile-run` case is also run as `node-run` when the case is listed in
  `504-node-target-emitter/conformance/corpus.txt`).

## Risks

- Module boundaries after inlining (see context) — resolve in step 3; if it
  needs a front-end change, do it there rather than reconstructing in the
  emitter.
- Narrowing: the checker rewrites some expressions in place for Zig's
  benefit (e.g. 303 ternary casts, 421 coalesce casts). Each such rewrite
  must be a no-op in JavaScript or be undone; list them while walking
  `emitExpr` and keep the list in the plan as they are handled.

# Tasks: 509 import alias on the node target

**Input**: spec.md's "What's confirmed" section.

- [x] T001 Traced how the checker resolves `import { x as y }`, and why the
  bug isn't actually about the import statement at all. The front end
  inlines every module into one flat `program.stmts` text
  (`appendExpandedSource`, `src/lumen.zig`) and, as part of that, textually
  rewrites `y` to `x`'s own physical name throughout the importing module's
  body (`addImportRename`/`appendTransformed`) *before* the real lexer/
  parser ever runs — so by the time the checker sees `b.ts`, there is no
  alias left to resolve: `currentWorkspaceRoot()` has already become
  `workspaceRoot()` in the source text. This collapse is correct and
  necessary for the native target (one flat namespace, one spelling per
  declaration) and harmless to the checker's own scope resolution (a nested
  `let workspaceRoot = workspaceRoot();` resolves its own RHS against the
  *outer* scope, since the new binding isn't in scope during its own
  initializer — standard block-scoping, and exactly why native prints
  `root\nroot` correctly).
  The real cause: the checker mints a real, unique `emit_name` for *every*
  local `let`/`const`/destructure/catch/param binding unconditionally
  (`freshEmitName`, spec 461's mechanism was already load-bearing for
  parameters), and every reference to it carries that same `emit_name` —
  but `lumen_emit_js_expr.zig`'s `.var_ref` case never consulted it,
  always printing the plain `name` "for readability" (FR-004). That is
  fine for Zig, which has no temporal dead zone, but JavaScript's `let`/
  `const` do: a local that reuses a name already bound at module scope
  (here, by the alias-collapse) throws `ReferenceError: Cannot access
  '<name>' before initialization` on any reference that lexically precedes
  or coincides with its own declaration in the same scope, even though the
  *outer* binding was the one actually meant.
- [x] T002 Fixed in the JS emitter, not the import/alias machinery (there
  was no alias left to preserve by the time it runs — see T001). Added
  `Emitter.shadowSafeName(name, emit_name)` (`lumen_emit_js.zig`): prints
  `name` unless this occurrence's `emit_name` both (a) is non-null (a
  local/param binding, not a function/class/import reference) and (b) does
  not match `top_level_var_emit_names[name]` (this module's own *direct*
  top-level `let`/`const`/destructure physical declaration of that name,
  if any — computed once for the whole flat program, since a reference to
  it can land in any importing module and every such reference shares the
  identical `emit_name`) — in which case it prints `emit_name` instead.
  Wired into every declaration/reference site that carries a `name` +
  `emit_name` pair: `var_ref` (expr), `var_decl`/`var_decl_group`,
  `destructure_decl` bindings, `Assign` (including compound `/=`),
  `using_decl` (both emission sites) and its synthesized `.dispose()`
  call, the `catch (name)` binding, and function/arrow parameters
  (`emitParams`) — the last one needed too: spec 461 already mangles a
  parameter that collides with a top-level name, and leaving parameters
  out made the declaration site plain while a shadowed reference inside
  printed the mangled form, the same class of decl/ref mismatch bug.
  Two false starts, both caught by actually running the output, not by
  reading the diff: gating on `body_depth == 0` (skip renaming for direct
  top-level statements) mismatched a top-level accumulator's own
  declaration against a *nested* reference to it (`let total = 0; for (...)
  { total += 1; }` — same single binding, both should print `total`, but
  depth-gating only protected the declaration); and building
  `top_level_var_emit_names` per *generated JS module* instead of once for
  the whole flat program mismatched a cross-module case (`export const
  ORIGIN` imported and referenced from a different file — its own
  `emit_name` isn't in the *importing* module's per-file map, so it fell
  through to the mangled form even though the import statement itself uses
  the plain name).
- [x] T003 Added `509.alias.node` (`node-run`, same expected `root\nroot`)
  alongside the existing `509.alias.native` in
  `specs/509-node-import-alias/conformance/manifest.json`. Already
  registered in `build.zig` (`conformance_cmd_509`, added when the bug was
  first found) — no new registration needed, just the new case.
- [x] T004 Confirmed via the full targeted sweep below: the single-
  reference-only case (`workspaceRoot__m1`-style mangling from the
  Expander, unrelated to this fix) is untouched, and every other
  import/export-collision spec still passes.
- [x] T005 `zig build test`: full pass. Targeted conformance (504, 505,
  506, 507, 508, 509, 461-parameter-shadowing, 476-exported-name-
  collisions, 488-class-and-type-alias-names — everything that exercises
  the node emitter's name handling): full pass, including the two
  regressions this task caught and fixed along the way (504's
  `node.modules`, 461's `arrow-shadowing-param`). `zig build conformance`
  (the whole suite) run as a final gate.
  Re-verified against Joule's actual `code.ts` (joule-sh/code): `lumen
  compile --target node src/code.ts` compiles clean (zero errors, only the
  same pre-existing unused-variable warnings), and `node code.node/code.mjs`
  (no args, no TTY) now reaches and passes the exact line that used to
  throw (`let workspaceRoot = currentWorkspaceRoot();` in
  `runDaemonJoule`, `src/terminal/attach.ts`), continuing on to the
  expected non-TTY message ("joule needs a real terminal") instead of
  `ReferenceError: Cannot access 'workspaceRoot' before initialization`.
  The generated `code.node/modules/terminal/attach.mjs` shows every
  shadowing local/param consistently renamed at both declaration and every
  reference (`__lumen_2883_workspaceRoot`, `__lumen_2889_workspaceRoot`,
  etc.), while the one non-shadowing reference (`runAttachStop(
  workspaceRoot(), ...)`) stays plain and readable.

# Spec 509: `import { x as y }` on the node target

**Status**: Draft (bug found while verifying spec 508 T013 against Joule's
real `code.ts`, not scheduled or investigated further) | **Parent**: 504

## Problem

`lumen compile --target node` drops an import alias. Given:

```ts
// a.ts
export function workspaceRoot(): string { return "root"; }
// b.ts
import { workspaceRoot as currentWorkspaceRoot } from "./a.ts";
let workspaceRoot = currentWorkspaceRoot();
console.log(workspaceRoot);
```

the generated `b.mjs` imports `{ workspaceRoot }` (the unaliased name), not
`{ workspaceRoot as currentWorkspaceRoot }` — even though every reference in
`b.ts`'s own body correctly uses `currentWorkspaceRoot`, as written. The
local `let workspaceRoot` (chosen specifically because the alias avoids a
collision with the import) now shadows the dropped-alias import, and the
program throws `ReferenceError: Cannot access 'workspaceRoot' before
initialization` — a JS temporal-dead-zone error, not something the source
program did wrong.

**A single reference to the alias is not enough to reproduce it** — that
case (checked directly: one function calling `currentWorkspaceRoot()`, no
colliding local anywhere) compiles to a *mangled* import
(`workspaceRoot__m1`) and runs correctly. The bug needs a SECOND function in
the same file whose own local variable is named the same as the plain
(unaliased) export — see `examples/valid/import_alias.ts`'s `second()`.
This narrows the likely cause: whatever decides "does this file need its
import mangled to avoid a collision" evidently treats the file as
collision-free once it sees the source already wrote an alias for this
import — reasonably, since the alias IS the collision fix as far as the
checker's own name resolution is concerned — but the JS emitter then
discards that manual alias when writing the import statement, recreating
the exact collision the alias was written to avoid. Two mechanisms
(automatic collision-mangling, and — the missing one — alias-preserving
import emission) interacting, not one simple oversight.

**Real, not synthetic**: found by compiling joule-sh/code's actual
`src/code.ts` with `--target node` and running the output, not by reading
the generated file. `src/terminal/attach.ts:37` has exactly this pattern
(`import { workspaceRoot as currentWorkspaceRoot } from
"../vendor/platform/platform.ts"`, `let workspaceRoot = ...` at line 77),
and `node code.node/code.mjs` crashes inside `runDaemonJoule` with the
error above. `joule --version` (which never reaches this code path) already
works; this is what blocks the next command tried past it.

Blast radius in Joule specifically is narrow —
`grep -rhoE "import \{[^}]* as [A-Za-z_]+[^}]*\}" src --include=*.ts`
(excluding `.test.ts`) finds 4 sites — but this is a general node-target
correctness bug, not a Joule-specific one: any Lumen program using
`import { x as y }` is affected the same way.

## What's confirmed, so the next investigation doesn't repeat it

- No `ImportDecl`/import-alias AST node exists. The front end inlines every
  module into one flat `program.stmts` list (spec 015/451's "multi-symbol
  modules" work); there is no runtime import statement in the AST to carry
  alias info on.
- `var_ref` (`lumen_ast.zig`) carries only `name` and `emit_name`.
  `emit_name` is the *native* Zig backend's own mangled-name concept
  (`freshEmitName`, used to avoid Zig-side collisions) — unrelated to
  imports, and already a source of one real bug this branch fixed
  (`Capture.name` vs `Capture.emit_name`, spec 508 T009). Do not conflate
  the two again.
- `attach.ts`'s own body correctly uses `currentWorkspaceRoot` everywhere
  (confirmed by reading the generated JS: every *reference* inside `b.mjs`
  after the import line says `currentWorkspaceRoot`, correctly). Only the
  IMPORT STATEMENT ITSELF gets the wrong name. This means whatever resolves
  "which declaration does this alias refer to" for type-checking purposes
  already works — the gap is specifically in `lumen_emit_js.zig`'s
  `emitImport` (~line 726) and the module `refs`/`exports` computation
  earlier in `emitProgram`, which decide *what name to write in the import
  line* using the declaring module's own name, with no way (yet found) to
  know the importing module calls it something else.
- Not yet traced: how the checker resolves `currentWorkspaceRoot` to
  `a.ts`'s `workspaceRoot` at all (there must be a symbol-table entry
  keyed by the local alias, pointing at the same binding/type) — start
  there; it is the most likely place the alias info already exists and
  could be threaded through to the JS emitter, rather than inventing a
  parallel mechanism.

## Requirements

- **FR-001**: `import { x as y }` on the node target imports the correct
  binding under the local alias name (`import { x as y } from "..."` in
  the generated JS, or equivalently any correct ESM spelling), so every
  reference to `y` in the importing module resolves to `x`'s declaration
  with no collision against an unrelated same-named binding elsewhere.
- **FR-002**: The native and wasm targets are unaffected (they do not use
  this code path).

## Success criteria

- **SC-001**: The minimal repro above (`examples/valid/`) prints `root` on
  the node target, matching native.
- **SC-002**: Joule's `code.ts`, compiled `--target node`, no longer
  crashes with this `ReferenceError` (verified by running past
  `runDaemonJoule`, not just recompiling).

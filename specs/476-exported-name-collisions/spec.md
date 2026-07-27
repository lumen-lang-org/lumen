# Spec 476: two modules may export the same name

## Goal

```ts
// mcp.ts
export function authHeaders(server: Server, token: string): Map<string, string> { … }

// provider.ts
export function authHeaders(provider: string, apiKey: string): Map<string, string> { … }

// run.ts — imports both
import { callTool } from "./mcp.ts";
import { complete } from "./provider.ts";
```

Today the third file fails:

```
mcp.ts:72:1: error: duplicate declaration of this name [E_DUPLICATE_BINDING]
```

Two modules choosing the same ordinary name for their own function is not a
mistake. `authHeaders` is the obvious name for "the headers that authenticate
this call", and it is the obvious name in both files. Neither author has read
the other's code; in TypeScript neither would need to.

## Why it happened

Imports are inlined into one flat program (`readSourceWithImports`,
`src/lumen.zig`). Spec 473 already absorbs the same clash for a **private**
declaration: a name nothing outside the module can reach is renamed by the
compiler and nobody notices. An **exported** declaration fell through to the
duplicate-binding error instead.

The distinction was unnecessary. Every module carries an export table mapping
its logical export names to their physical names in the flat program
(`info.exports`), and importers already resolve through it — that table is how
`import { x as y }` works. So renaming an exported definition is invisible to
the importer too; the machinery to make it invisible was already there and
simply was not used for this case.

Found while building std-contrib's `agents` package: `mcp.ts` and
`provider.ts` each wanted `authHeaders`, and the package worked around it by
renaming one to `mcpAuthHeaders` — a language defect paid for in a worse name,
which CLAUDE.md forbids.

## Semantics

When a value declaration's name is already claimed by a **different** module,
the compiler renames the definition and rewrites that module's own references,
whether or not the declaration is exported. Importers are unaffected: a named
import resolves through the exporting module's table, which records the
physical name.

"Different module" is by canonical key, not path. One module reached by two
paths is one module and never clashes with itself — renaming it against itself
would break the second importer.

One case is **not** a coincidence and still fails: a file that both imports a
name and declares it itself.

```ts
import { add, mul } from "./mathlib.ts";
function add(a: int, b: int): int { … }   // error: E_DUPLICATE_BINDING
```

Here the author asked for `add` and then wrote `add` again, so `add(1, 2)` has
two readings and only they can say which was meant. Absorbing the clash would
silently pick one. The rule above covers two authors who never met; this is one
author contradicting themselves, and the compiler names the file's own line.

The first cut of this change missed the case, because the collision is absorbed
on the *other* side: a module's own declarations are recorded before its
imports are expanded, so it is the imported module's export that gets renamed
out of the way. The check therefore lives at the binding, where both the local
declarations and the imported names are known — not in the declaration loop.

Type names are unchanged: two modules declaring the same **type** still fail,
with both module paths named (spec 451 D3). A type is structural here and a
silent rename would let two different shapes wear one name in the same
program, which is a real conflict rather than a spelling coincidence.

## Success Criteria

- **SC-001**: Two modules each exporting `LIMIT`, both imported by a third,
  compile and each function sees its own value.
- **SC-002**: A module reached twice by different relative paths is still one
  module — the second importer's reference resolves.
- **SC-003**: Spec 473's private-clash behaviour is unchanged.
- **SC-004**: Two modules declaring the same type name still fail with both
  paths named.
- **SC-005**: A file that imports `add` and also declares `add` still fails
  with `E_DUPLICATE_BINDING`, reported against its own declaration
  (`modules.invalid.duplicate-binding`, spec 015).

## Implementation

`src/lumen.zig` — the clash branch in the declaration loop drops its
`!d.exported` condition and asks `ownedByOther(name, id)` instead of
`claimed(name)`, so it fires only for a genuinely different module and covers
exported declarations too.

The import-shadowing check sits in the import loop of the same function, just
before the child is expanded: for each name an import line binds
(`importedAliases`), a hit in this module's own `physical` table raises
`error.ShadowedImport`, reported as `E_DUPLICATE_BINDING` against the
declaration's line.

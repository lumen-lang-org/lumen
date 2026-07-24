# Feature Specification: Exported Type Aliases And Module-Scoped Imports

## Problem

Lumen's import system is a textual pre-processor: `readSourceWithImports`
(`src/lumen.zig:742`) inlines each imported module's source into one flat
program. That design is cheap and works, but it has two defects that together
make a package impossible to split across module or package boundaries.

### 1. A type alias cannot be exported

`src/lumen.zig:733`:

```zig
if (std.mem.startsWith(u8, trimmed, "export ")) return error.InvalidImport;
```

`parseNamedExportDecl` (`src/lumen.zig:298`) recognises exactly three
declaration forms — `export function`, `export const`, `export let` — plus
`export { a, b }` lists. Every other `export` form is rejected:

```ts
export type Point = { x: int, y: int };
```

```
error: unsupported import syntax [E_UNSUPPORTED_IMPORT]
```

So a module can export behaviour but not the shape that behaviour speaks in. A
consumer must redeclare the type — and because every module is inlined into one
flat namespace, the redeclaration collides:

```
error: duplicate declaration of this name [E_DUPLICATE_BINDING]
```

The std-contrib `ai` package works around this today by having each module
import an arbitrary *value* from a sibling purely to drag that sibling's
unexported type into scope. It is a workaround for a missing feature, and it is
documented as such in that package's own spec ("exported type aliases are not
supported by module imports").

### 2. An aliased import renames the definition globally

`src/lumen.zig:636-644` builds a rename list from aliased named imports and
applies it while inlining the *source* module:

```zig
// Renames from aliased named imports (`a as b`) -> rename `a` to `b` in this
// inlined module so importer references to `b` resolve ...
```

The rename rewrites **the declaration**, not the importing module's references.
So if module A imports `foo` unaliased and module B imports `foo as bar`, the
single definition is renamed to `bar` and A's reference to `foo` dangles:

```
error: undefined variable 'foo'
```

This is not hypothetical. Building the std-contrib `ai` package hit this three
separate times in one day — on `mcp.ts`, on `output.ts`, and on the barrel's
tool imports. Each time the fix was to discover which names a sibling imported
bare and force the barrel to import those same names bare, then rename the
public wrapper instead. The package now carries three separate comment blocks
explaining the rule to the next reader. That is a language defect being paid
for in documentation.

## Reproductions

### R1 — exported type alias

`point.ts`
```ts
export type Point = { x: int, y: int };
export function origin(): Point { return { x: 0, y: 0 }; }
```

`main.ts`
```ts
import { Point, origin } from "./point.ts";
let p: Point = origin();
console.log(`${p.x},${p.y}`);
```

Today: `error: unsupported import syntax [E_UNSUPPORTED_IMPORT]`.
Wanted: compiles, prints `0,0`.

### R2 — aliased import must not break a sibling

`lib.ts`
```ts
export function greet(name: string): string { return "hi " + name; }
```

`mid.ts`
```ts
import { greet } from "./lib.ts";
export function loud(name: string): string { return greet(name).toUpperCase(); }
```

`main.ts`
```ts
import { greet as hello } from "./lib.ts";
import { loud } from "./mid.ts";
console.log(hello("a") + " " + loud("b"));
```

Today: `error: undefined variable 'greet'` — the definition was renamed to
`hello`, so `mid.ts` dangles.
Wanted: compiles, prints `hi a HI B`.

### R3 — two modules declaring the same type name

Two unrelated modules each declaring `type Result = ...` collide with
`E_DUPLICATE_BINDING` pointing at the second declaration, with no indication
that the conflict is between two files.

## Scope

In scope:

- `export type NAME = ...` is a valid export, importable by name.
- A type-only import binds the alias for annotations; it emits no runtime
  declaration of its own.
- An aliased named import renames references **in the importing module only**;
  the declaration keeps its original name and other modules importing it bare
  continue to resolve.
- A duplicate type-name collision reports both the declaring modules and the
  name, instead of a bare `E_DUPLICATE_BINDING` at an arbitrary line.
- The same module reached by two different paths (a relative path and a URL, or
  two URLs differing only by trailing slash) is inlined once, so a shared
  dependency does not self-collide.

Out of scope:

- A real (non-textual) module system with per-module namespaces. This spec
  keeps the inlining pre-processor and fixes its two defects; replacing it is a
  much larger change and should be its own slice.
- `export default` for types, `export * from`, and type-only import syntax
  (`import type { T }`). A plain named import of a type is enough to unblock
  package composition.
- Generic type aliases with parameters crossing a module boundary, beyond what
  already works within one file.

## Design

### D1 — `export type`

Extend `parseNamedExportDecl` with an `export type ` prefix so the name is
collected by `collectExports` (making a named import of it validate) and the
`export ` keyword is stripped when the module is inlined. The declaration then
flows into the flat program exactly as a function or const does. This is the
small half of the work.

### D2 — rename at the reference site, not the declaration

Invert the current rename direction. Today, inlining module M applies
`a -> b` to M's own text. Instead:

- inline M unchanged, so its declaration keeps the name `a`;
- when appending the **importing** module's text, rewrite its references from
  `b` back to `a`.

`appendTransformed` already does identifier-aware rewriting (skipping string
literals and comments), so the machinery exists; what changes is which file the
rename list is applied to. Two importers can then alias the same symbol
differently, and an importer that does not alias is unaffected.

The collision that aliasing was *originally* meant to solve — two different
modules exporting the same name — must still be handled. With D2 the definitions
would now clash. Resolve it by renaming the *definition* only when two distinct
modules genuinely export the same name, and rewriting every reference in the
importer that asked for it; a single-definition name is never renamed.

### D3 — collision diagnostics

When a type name is declared by two distinct inlined modules, fail with the name
and both module paths, at the second declaration's own line, rather than the
generic duplicate-binding error.

### D4 — module identity

Canonicalise the dedup key already used for "the module is already inlined"
(`src/lumen.zig:601`): resolve relative paths to a real path, and normalise URLs
(scheme/host case, trailing slash) so one module fetched two ways inlines once.

## Success Criteria

1. R1 compiles and prints `0,0`.
2. R2 compiles and prints `hi a HI B`.
3. A type exported from one module and imported by two others compiles, with a
   single declaration in the generated Zig.
4. Two modules exporting the same *function* name, imported by one file under
   different aliases, both resolve.
5. R3 reports both declaring modules by path.
6. A module imported once relatively and once by URL is inlined once.
7. The std-contrib `ai` package compiles after removing its three
   import-aliasing workaround comments and the value-imports that exist only to
   drag a type into scope.
8. `zig build test` passes; `zig build conformance` adds no new failures against
   the 169-passed / 50-failed baseline.

## Risks

- **D2 is a behaviour change to every aliased import.** Programs that currently
  rely on the definition being renamed are, by definition, the broken case — but
  the conformance suite must confirm nothing depended on it. Specs 015
  (multi-symbol modules) and any example using `as` are the ones to re-run first.
- **Type aliases are erased.** A type-only import must not emit a runtime
  declaration; check how the checker's `type_decls` interacts with a name that
  has no value.
- **Textual rewriting stays textual.** Renaming references in the importer is
  still a token-level rewrite; a name that appears as a record *field* or an
  object key must not be rewritten. `appendTransformed` already skips strings and
  comments, but field positions need a test.
- **Diamond dependencies.** With type sharing, two packages depending on the same
  core become common. D4 handles identical modules; two *different versions* of
  the same package still collide, and should fail with a clear message rather
  than a confusing duplicate declaration.

## Notes

The payoff is concrete: this is the precondition for splitting a package. The
std-contrib `ai` package is 9,684 lines with only 4% provider-specific code, and
splitting providers into their own packages is blocked today purely because a
provider package cannot share `AiMessage`/`AiResult` with the core. Once a type
can be exported and imported, that split becomes a packaging decision rather
than a language limitation.

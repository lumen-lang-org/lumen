# Tasks: Exported Type Aliases And Module-Scoped Imports

## Investigation

- [ ] Confirm every `export` form `parseNamedExportDecl` recognises today
      (`src/lumen.zig:298`) and which line rejects the rest (`:733`).
- [ ] Trace how a rename list is built and applied while inlining
      (`src/lumen.zig:636-644`, `appendTransformed` at `:496`) and confirm it
      rewrites the declaration rather than the importer's references.
- [ ] Determine how the checker stores type aliases (`type_decls`) and what a
      name with no runtime value does to emission.
- [ ] Find the dedup key for "module already inlined" (`src/lumen.zig:601`) and
      what makes two paths compare unequal today.

## D1 — export type

- [ ] Recognise `export type NAME = ...` in `parseNamedExportDecl`.
- [ ] Include exported type names in `collectExports` so a named import of a
      type validates instead of reporting E_MISSING_EXPORT.
- [ ] Strip the `export ` keyword when inlining so the alias flows into the flat
      program.
- [ ] Ensure a type-only import emits no runtime declaration.

## D2 — module-scoped aliasing

- [ ] Stop applying the rename list to the inlined source module.
- [ ] Apply the rename in the importing module's text instead (alias -> original).
- [ ] Rename a definition only when two distinct modules export the same name,
      and rewrite the references of the importer that asked for it.
- [ ] Confirm an importer that does NOT alias still resolves the bare name.
- [ ] Confirm two importers may alias the same symbol differently.

## D3 — collision diagnostics

- [ ] Report a duplicate type name with the name and both declaring module paths.
- [ ] Point the diagnostic at the second declaration's own line.

## D4 — module identity

- [ ] Canonicalise relative paths to a real path for the dedup key.
- [ ] Normalise URLs (scheme/host case, trailing slash) for the dedup key.
- [ ] A module imported once relatively and once by URL inlines once.

## Tests

- [ ] R1: exported type alias imported and used as an annotation.
- [ ] R2: aliased import does not break a sibling that imports the name bare.
- [ ] A type exported once and imported by two modules yields one declaration.
- [ ] Two modules exporting the same function name, aliased differently by one
      importer, both resolve.
- [ ] A record field or object key matching an alias is NOT rewritten.
- [ ] A type imported but never used compiles and emits nothing.
- [ ] Duplicate type names across modules report both paths.
- [ ] Same module via relative path and URL inlines once.

## Gates

- [ ] `zig build` and `zig build test` pass.
- [ ] One clean `zig build conformance` run: no new failures against the
      169 passed / 50 failed baseline.
- [ ] Re-run spec 015 (multi-symbol modules) and every example using `as`,
      since D2 changes aliasing behaviour.
- [ ] Add R1 and R2 as conformance examples with a manifest wired into build.zig.

## Follow-up (not this slice)

- [ ] Remove the std-contrib `ai` package's three import-aliasing workaround
      comments and the value-imports that exist only to pull a type into scope.
- [ ] Revisit splitting providers into their own package, which this unblocks.

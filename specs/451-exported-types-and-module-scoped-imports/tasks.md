# Tasks: Exported Type Aliases And Module-Scoped Imports

## Investigation

- [x] Confirm every `export` form `parseNamedExportDecl` recognises today
      (`src/lumen.zig:298`) and which line rejects the rest (`:733`).
- [x] Trace how a rename list is built and applied while inlining
      (`src/lumen.zig:636-644`, `appendTransformed` at `:496`) and confirm it
      rewrites the declaration rather than the importer's references.
- [x] Determine how the checker stores type aliases (`type_decls`) and what a
      name with no runtime value does to emission.
- [x] Find the dedup key for "module already inlined" (`src/lumen.zig:601`) and
      what makes two paths compare unequal today.

## D1 — export type

- [x] Recognise `export type NAME = ...` in `parseNamedExportDecl`.
- [x] Include exported type names in `collectExports` so a named import of a
      type validates instead of reporting E_MISSING_EXPORT.
- [x] Strip the `export ` keyword when inlining so the alias flows into the flat
      program.
- [x] Ensure a type-only import emits no runtime declaration.

## D2 — module-scoped aliasing

- [x] Stop applying the rename list to the inlined source module.
- [x] Apply the rename in the importing module's text instead (alias -> original).
- [x] Rename a definition only when two distinct modules export the same name,
      and rewrite the references of the importer that asked for it.
- [x] Confirm an importer that does NOT alias still resolves the bare name.
- [x] Confirm two importers may alias the same symbol differently.

## D3 — collision diagnostics

- [x] Report a duplicate type name with the name and both declaring module paths.
- [x] Point the diagnostic at the second declaration's own line.

## D4 — module identity

- [x] Canonicalise relative paths to a real path for the dedup key.
- [x] Normalise URLs (scheme/host case, trailing slash) for the dedup key.
- [x] A module reached by two spellings of the same source inlines once. Note: a
      local file and an `https://` URL are different *sources*, so they can never
      share a key; what canonicalisation unifies is two spellings of the same
      source -- two relative paths (`./x.ts` from one directory, `../x.ts` from
      another), or two URLs differing only in scheme/host case, a default `:443`,
      `.`/`..`/empty segments, or a trailing slash.

## Tests

- [x] R1: exported type alias imported and used as an annotation.
- [x] R2: aliased import does not break a sibling that imports the name bare.
- [x] A type exported once and imported by two modules yields one declaration.
- [x] Two modules exporting the same function name, aliased differently by one
      importer, both resolve.
- [x] A record field or object key matching an alias is NOT rewritten.
- [x] A type imported but never used compiles and emits nothing.
- [x] Duplicate type names across modules report both paths.
- [x] Same module via two relative spellings inlines once (conformance);
      URL canonicalisation is covered by a unit test, since conformance cannot
      depend on the network.

## Gates

- [x] `zig build` and `zig build test` pass.
- [x] One clean `zig build conformance` run: no new failures against the
      169 passed / 50 failed baseline.
- [x] Re-run spec 015 (multi-symbol modules) and every example using `as`,
      since D2 changes aliasing behaviour.
- [x] Add R1 and R2 as conformance examples with a manifest wired into build.zig.

## Follow-up (not this slice)

- [ ] Remove the std-contrib `ai` package's three import-aliasing workaround
      comments and the value-imports that exist only to pull a type into scope.
- [ ] Revisit splitting providers into their own package, which this unblocks.

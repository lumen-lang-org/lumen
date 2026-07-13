# 401 — generic type aliases with a non-record body resolve on use

## Problem

Generic aliases whose right-hand side is a plain type, optional, or array —
rather than a record `{ … }` — reported "unknown generic type" at the use site:

```ts
type Id<T> = T;         let a: Id<number> = 5;         // unknown generic type
type Opt<T> = T | null; let b: Opt<number> = 5;        // unknown generic type
type List<T> = T[];     let c: List<number> = [1,2,3]; // unknown generic type
```

Two gaps:

1. **Parser** — the single-member, optional (`T | null` → `T?`), and union return
   paths in `parseTypeDecl` dropped the parsed `type_params`, so the alias never
   registered as generic. (Record and function-type bodies already kept them.)
2. **Checker** — `specializeType` only substitutes into record `fields`; an
   alias-bodied generic has none, so it would have synthesized an empty record
   instead of resolving to the aliased type.

## Approach

- **Parser** (`lumen_parser_decl.zig`): thread `type_params` into the
  single-member alias, optional-alias, and `union_variants` return values.
- **Checker** (`lumen_check.zig`, generic-type resolution): when the generic
  declaration is an alias (`gt.alias != null`), substitute the type arguments
  into its target annotation with `substAnnotation` and resolve that directly,
  rather than calling `specializeType`.

## Verification

- `Id<number>` → `5`; `Id<T>=T` no-space form → `5`.
- `Opt<number>` (from `T | null`) holds `5` and `null` (`?? -1` → `-1`).
- `List<number>` → `[1,2,3]`; `List<string>` → `a-b`.
- Nested alias `type Grid<T> = List<T>` + `Grid<number>` → `1,2`.
- Record-bodied generics (`type Box<T> = { v:T }`) unchanged.
- Full `zig build` + test suite green.

## Notes

Builds directly on spec 400 (parsing the `>=`-glued close token). Generic
aliases over discriminated *unions* of generic variants
(`type R<T> = Ok<T> | Err`) still specialize through the record path and are not
part of this change.

# Spec 320 — Utility-type guidance and array-of-optional display

## Goal

Give actionable diagnostics for unsupported TypeScript utility types, and fix the
type display for an array of optionals.

## Motivation

- `Record<string, i32>` and mapped utility types (`Partial`, `Readonly`,
  `Required`, `Pick`, `Omit`) reported a bare `unknown generic type`, leaving no
  hint about the supported alternative.
- An array whose element is optional printed as `i32 | null[]`, which reads as an
  array of `null`-or-`i32[]` rather than `(i32 | null)[]`.

## Behavior

- `Record<K, V>` reports: use `Map<K, V>` for dynamic key/value storage, or a
  named `type` with fixed fields.
- `Partial`/`Readonly`/`Required`/`Pick`/`Omit` report: declare an explicit named
  `type` with the fields you need.
- A compound array element type is parenthesized in diagnostics:
  `(i32 | null)[]`, and likewise for arrays of function types.

## Implementation

- `src/lumen_check.zig`: `typeFromAnnotation` special-cases `Record` and the
  common mapped utility types before the generic-type fallback.
- `src/lumen_types.zig`: `tsName` parenthesizes a `nested_array` element that is
  an optional or function type.

## Verification

- `zig build` and `zig build test` green.
- `Record<...>` and `Partial<...>` produce their guidance; an unknown generic
  still reports the generic message; `parseInt`-mapped array mismatches now read
  `(i32 | null)[]`.

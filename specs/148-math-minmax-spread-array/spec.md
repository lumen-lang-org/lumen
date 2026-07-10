# Spec 148: Math.min / Math.max over a spread array

## Goal

Support `Math.min(...arr)` and `Math.max(...arr)` — the idiomatic way to take the
minimum or maximum of a numeric array in JavaScript:

```ts
const a = [3, 1, 4, 1, 5, 9, 2, 6];
Math.min(...a)   // 1   (was E_ARG_COUNT)
Math.max(...a)   // 9
```

Previously `Math.min`/`Math.max` accepted only two-or-more explicit arguments; a
spread of an array was rejected.

## Why additive, not breaking

Only makes previously-rejected programs compile. The explicit-argument variadic
form is unchanged.

## Semantics

`Math.min(...arr)` / `Math.max(...arr)`, where `arr` is a numeric array
(`i32[]`, `i64[]`, `f64[]`), folds `@min`/`@max` over the elements and returns a
value of the element type. Exactly one spread argument is supported (matching the
common use); the array must be non-empty at runtime.

## Requirements

- **FR-001**: `Math.min(...arr)` / `Math.max(...arr)` return the min/max element
  of a numeric array, typed as the element type.
- **FR-002**: A spread of a non-numeric array reports `E_TYPE_MISMATCH`.
- **FR-003**: The explicit-argument form `Math.min(a, b, …)` is unchanged.

## Success Criteria

- **SC-001**: `Math.min(...[3,1,4,1,5,9,2,6])` -> `1`;
  `Math.max(...[3,1,4,1,5,9,2,6])` -> `9`.
- **SC-002**: `Math.max(...[2.5, 1.5, 3.5])` (an `f64[]`) -> `3.5`.
- **SC-003**: `Math.min(5, 3, 8)` -> `3` (explicit args unchanged).
- **SC-004**: `zig build` and `zig build test` stay green.

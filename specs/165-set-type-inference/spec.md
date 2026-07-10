# Spec 165: Set element-type inference from the initializer

## Goal

Let `new Set(arr)` infer its element type from the initializer array, so the
`<T>` type argument can be omitted, matching TypeScript:

```ts
const unique = Array.from(new Set([1, 2, 2, 3]));  // Set<i32> inferred
new Set(["a", "b", "a"]).size;                     // Set<string> inferred
```

Previously the `Set` constructor always required an explicit `<T>` type
argument; `new Set(arr)` reported `E_TYPE_ARG_COUNT`.

## Why additive, not breaking

Only makes previously-rejected programs compile. `new Set<T>()` and
`new Set<T>(arr)` (explicit type argument) are unchanged.

## Semantics

When `new Set` is written with no `<T>` type argument but one array initializer,
the element type `T` is inferred from the array's element type. The explicit
forms are unchanged; a `new Set` with neither a type argument nor an inferable
initializer still reports `E_TYPE_ARG_COUNT`.

## Requirements

- **FR-001**: `new Set(arr)` (no type argument) infers `T` from `arr`'s element
  type.
- **FR-002**: `new Set<T>(arr)` and `new Set<T>()` are unchanged.
- **FR-003**: `new Set()` with no type argument and no initializer reports
  `E_TYPE_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Array.from(new Set([1,2,2,3,3,4]))` -> `[1, 2, 3, 4]`.
- **SC-002**: `new Set(["a","b","a","c"]).size` -> `3`.
- **SC-003**: `new Set<i32>([5,5,6]).size` -> `2` (explicit unchanged).
- **SC-004**: `zig build` and `zig build test` stay green.

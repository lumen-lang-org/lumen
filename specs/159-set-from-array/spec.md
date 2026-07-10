# Spec 159: new Set(array) initializer

## Goal

Allow a `Set` to be constructed from an array of elements, as in JavaScript:

```ts
const set = new Set<i32>([1, 2, 3, 2, 1]);  // size 3 (deduped)
const strs = new Set<string>(["a", "b", "a"]);  // size 2
```

Previously the `Set` constructor accepted no arguments; an initializer array
reported `E_ARG_COUNT`.

## Why additive, not breaking

Only makes previously-rejected programs compile. `new Set<T>()` (empty) is
unchanged.

## Semantics

`new Set<T>(arr)` creates an empty set and adds each element of `arr` in order;
duplicates collapse (set semantics). The array's element type must match the
set's element type `T`.

## Requirements

- **FR-001**: `new Set<T>(arr)` initializes the set with the array's elements.
- **FR-002**: Duplicate elements collapse to one.
- **FR-003**: The array element type must equal `T`, else `E_TYPE_MISMATCH`.
- **FR-004**: `new Set<T>()` (empty) is unchanged.

## Success Criteria

- **SC-001**: `new Set<i32>([1,2,3,2,1]).size` -> `3`.
- **SC-002**: `new Set<string>(["a","b","a"]).size` -> `2`.
- **SC-003**: `new Set<i32>([1,2,3]).has(2)` -> `true`; `.has(9)` -> `false`.
- **SC-004**: `new Set<i32>().size` -> `0`.
- **SC-005**: `zig build` and `zig build test` stay green.

# Spec 162: Array.from(Set)

## Goal

Let `Array.from` accept a `Set`, returning its elements as an array — enabling
the common "dedupe an array" idiom:

```ts
const unique = Array.from(new Set<i32>([3, 1, 2, 1, 3]));  // [3, 1, 2]
Array.from(new Set(arr)).toSorted();
```

Previously `Array.from` accepted only a string or an array; a set reported
`E_TYPE_MISMATCH`.

## Why additive, not breaking

Only makes previously-rejected programs compile. `Array.from(string)` and
`Array.from(array)` are unchanged.

## Semantics

`Array.from(set)` returns a new array containing the set's elements in insertion
order (the set already holds each value once), typed as `T[]` for a
`Set<T>`.

## Requirements

- **FR-001**: `Array.from(set)` returns the set's elements as a `T[]`.
- **FR-002**: The result is a fresh array (usable with every array method).
- **FR-003**: `Array.from(string)` / `Array.from(array)` are unchanged.

## Success Criteria

- **SC-001**: `Array.from(new Set<i32>([3,1,2,1,3]))` -> `[3, 1, 2]` (length 3).
- **SC-002**: `Array.from(new Set<i32>([3,1,2])).toSorted()` -> `[1, 2, 3]`.
- **SC-003**: `Array.from(new Set<string>(["b","a","b"])).sort()` ->
  `['a', 'b']`.
- **SC-004**: `zig build` and `zig build test` stay green.

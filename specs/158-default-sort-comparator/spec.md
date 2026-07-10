# Spec 158: sort() / toSorted() with no comparator

## Goal

Allow `sort` and `toSorted` to be called with no comparator, defaulting to
ascending order:

```ts
[5, 2, 8, 1, 9].sort();              // [1, 2, 5, 8, 9]
["banana", "apple", "cherry"].sort(); // ['apple', 'banana', 'cherry']
```

Previously a comparator was required; `arr.sort()` reported `E_ARG_COUNT`.

## Why additive, not breaking

Only makes previously-rejected programs compile. The comparator form
`sort((a, b) => ...)` is unchanged.

## Semantics

With no comparator, the array is sorted ascending:

- **Numeric elements** (`i32`/`i64`/`f64`): numeric ascending. (This is more
  useful and less surprising than JavaScript's default, which coerces to strings
  and would order `[1, 10, 2]`.)
- **String elements**: lexicographic (byte) order.

The element type must be numeric or string; any other element type reports
`E_TYPE_MISMATCH`. As with the comparator form, the source array is unchanged and
a new sorted array is returned.

## Requirements

- **FR-001**: `arr.sort()` / `arr.toSorted()` with no argument returns an
  ascending-sorted copy.
- **FR-002**: Numeric arrays sort numerically; string arrays sort
  lexicographically.
- **FR-003**: A non-comparable element type reports `E_TYPE_MISMATCH`.
- **FR-004**: The comparator form is unchanged.

## Success Criteria

- **SC-001**: `[5,2,8,1,9].sort()` -> `[1, 2, 5, 8, 9]`.
- **SC-002**: `["banana","apple","cherry"].sort()` ->
  `['apple', 'banana', 'cherry']`; `[3,1,2].toSorted()` -> `[1, 2, 3]`.
- **SC-003**: `[5,2,8].sort((x, y) => y - x)` -> `[8, 5, 2]` (comparator
  unchanged).
- **SC-004**: `zig build` and `zig build test` stay green.

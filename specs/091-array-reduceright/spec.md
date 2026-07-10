# Spec 091: array reduceRight

## Goal

`reduce` folds left-to-right. `reduceRight` is its right-to-left counterpart,
needed whenever fold order matters (building a string from the end, right-
associative composition).

## Why additive, not breaking

Pure addition to `arrayMethod`, sharing `reduce`'s type-checking (same callback
shapes and accumulator handling, including the optional index). Only the emitted
loop direction differs.

## API

Instance method on a `T[]` value:

- `reduceRight(fn: (U, T) => U | (U, T, int) => U, init: U): U` — fold from the
  last element to the first, starting at `init`. The optional third callback
  parameter is the element's index (which descends).

## Requirements

- **FR-001**: The reducer must take the accumulator and element, optionally
  followed by an integer index, and return the accumulator type; any other
  shape reports `E_TYPE_MISMATCH`. `reduceRight` requires exactly two arguments,
  else `E_ARG_COUNT`.
- **FR-002**: Elements are visited from the highest index down to `0`; when the
  callback declares the index it receives the true descending position.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `["a","b","c"].reduceRight((a, v) => a + v, "")` -> `"cba"`;
  `[1,2,3,4].reduceRight((a, v, i) => a + v * i, 0)` -> `20`;
  `[1,2,3,4].reduceRight((a, v) => a + v, 0)` -> `10`.
- **SC-002**: `zig build` and `zig build test` stay green.

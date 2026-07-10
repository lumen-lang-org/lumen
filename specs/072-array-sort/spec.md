# Spec 072: array sort

## Goal

`sort` is the last common array operation missing. It orders elements by a
comparator and, like `reverse`/`concat`, returns a new array without mutating
the receiver — keeping the immutable-array model intact.

## Why additive, not breaking

Pure addition to `arrayMethod`. It reuses the callback machinery (a
`(T, T) => int` comparator invoked through the uniform function value) and
lowers to `std.mem.sort`, which is stable.

## API

Instance method on a `T[]` value:

- `sort(cmp: (a: T, b: T) => int): T[]` — a new array ordered so that a
  negative `cmp(a, b)` places `a` before `b`, zero keeps their relative order
  (stable), positive places `a` after `b`. The receiver is unchanged.

## Requirements

- **FR-001**: `sort` takes exactly one argument, a `(T, T) => int` comparator;
  a wrong callback shape reports `E_TYPE_MISMATCH`, a wrong count reports
  `E_ARG_COUNT`.
- **FR-002**: The result is a new array; the receiver reads its original order
  afterward.
- **FR-003**: The sort is stable: elements the comparator reports as equal keep
  their input order.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `[3,1,4,1,5,9,2,6].sort((a,b) => a - b).join(",")` ->
  `1,1,2,3,4,5,6,9`; the descending comparator reverses it; the source array
  still reads its original order. Empty and single-element arrays are handled.
- **SC-002**: `zig build` and `zig build test` stay green.

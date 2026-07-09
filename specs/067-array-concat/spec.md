# Spec 067: array concat

## Goal

`slice`/`reverse` (spec 066) cover re-shaping one array; joining two arrays was
still missing. `concat` returns a new array with the receiver's elements
followed by the argument's, leaving both sources untouched — the same
immutable-array model as `reverse`.

## Why additive, not breaking

Pure addition to `arrayMethod`. The argument must be an array assignable to the
receiver's type, so the element type is preserved with no widening.

## API

Instance method on a `T[]` value:

- `concat(other: T[]): T[]` — a new array: receiver elements then `other`'s
  elements. Neither source is mutated. Empty operands are handled (either side).

## Requirements

- **FR-001**: `concat` takes exactly one argument; a wrong count reports
  `E_ARG_COUNT`.
- **FR-002**: The argument must be assignable to the receiver's array type; a
  mismatched element type reports `E_TYPE_MISMATCH`.
- **FR-003**: The result length is `receiver.length + other.length`; neither
  source array is modified.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `[1,2,3].concat([4,5]).join(",")` -> `1,2,3,4,5`; both operands
  still read their original contents afterward; empty-operand concat on either
  side yields the other operand's contents.
- **SC-002**: Concatenating arrays of different element types fails before
  native build.
- **SC-003**: `zig build` and `zig build test` stay green.

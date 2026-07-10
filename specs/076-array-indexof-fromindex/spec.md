# Spec 076: array indexOf/includes fromIndex

## Goal

The string `indexOf` gained a `fromIndex` (spec 074); the array searches lacked
the same. This adds the optional start index to `indexOf` and `includes` so a
scan can begin partway through the array, matching JavaScript.

## Why additive, not breaking

Pure extension of the existing `indexOf`/`includes` array methods. The
single-argument forms are unchanged; a second integer argument sets a start
index. `lastIndexOf` is intentionally left single-argument.

## API

Instance methods on a `T[]` value:

- `indexOf(x: T, from?: int): int` — first index `>= from` whose element equals
  `x`, or `-1`.
- `includes(x: T, from?: int): bool` — whether any element at index `>= from`
  equals `x`.

`from` counts from the end when negative (as for array `at`), clamped into
`[0, length]`.

## Requirements

- **FR-001**: Each accepts the element value, optionally followed by one
  integer; a non-integer start reports `E_TYPE_MISMATCH`, and more than two
  arguments reports `E_ARG_COUNT`. `lastIndexOf` still rejects a second
  argument.
- **FR-002**: A negative `from` maps to `length + from` (floored at `0`); the
  scan starts there.
- **FR-003**: The single-argument forms behave exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `[10,20,30,20,10]`: `indexOf(20, 2)` -> `3`,
  `indexOf(10, -1)` -> `4`, `includes(30, 3)` -> `false`,
  `includes(10, -1)` -> `true`.
- **SC-002**: `zig build` and `zig build test` stay green.

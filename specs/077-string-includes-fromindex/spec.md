# Spec 077: string includes fromIndex

## Goal

`indexOf` gained a `fromIndex` (spec 074); `includes` is its boolean sibling and
should accept the same optional start position. This lets a caller test for a
substring only in the tail of a string without re-slicing.

## Why additive, not breaking

Pure extension of the existing `includes` string method: the single-argument
form is unchanged; a second integer argument switches the lowering from
`std.mem.indexOf` to `std.mem.indexOfPos`.

## API

Instance method on a `string` value:

- `includes(sub: string, fromIndex?: int): bool` — whether `sub` occurs at or
  after `fromIndex` (default `0`). `fromIndex` is clamped into `[0, length]`;
  negative values clamp to `0` (consistent with string `indexOf`).

## Requirements

- **FR-001**: `includes` accepts one string, optionally followed by one
  integer; a non-string needle or non-integer index reports `E_TYPE_MISMATCH`,
  and more than two arguments reports `E_ARG_COUNT`.
- **FR-002**: With `fromIndex`, only occurrences at or after the clamped
  position count.
- **FR-003**: The single-argument form behaves exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `"abcabc"`: `includes("bc")` -> `true`,
  `includes("bc", 2)` -> `true`, `includes("bc", 5)` -> `false`,
  `includes("bc", -3)` -> `true`.
- **SC-002**: `zig build` and `zig build test` stay green.

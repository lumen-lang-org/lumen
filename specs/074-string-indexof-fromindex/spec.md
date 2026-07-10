# Spec 074: string indexOf fromIndex

## Goal

`indexOf` could only search from the start, so scanning for repeated
occurrences meant re-slicing the string. This adds the optional `fromIndex`
second argument (as in JavaScript), letting a caller resume a search past a
previous match.

## Why additive, not breaking

Pure extension of the existing `indexOf` string method: the single-argument
form is unchanged; a second integer argument switches the lowering from
`std.mem.indexOf` to `std.mem.indexOfPos`.

## API

Instance method on a `string` value:

- `indexOf(sub: string, fromIndex?: int): int` — byte index of the first
  occurrence of `sub` at or after `fromIndex` (default `0`), or `-1`.
  `fromIndex` is clamped into `[0, length]`; negative values clamp to `0`.

## Requirements

- **FR-001**: `indexOf` accepts one string, optionally followed by one integer;
  a non-string needle or non-integer index reports `E_TYPE_MISMATCH`, and more
  than two arguments reports `E_ARG_COUNT`.
- **FR-002**: With `fromIndex`, the search starts at the clamped position; the
  result is `-1` when there is no occurrence at or after it.
- **FR-003**: The single-argument form behaves exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `"abcabcabc"`: `indexOf("bc")` -> `1`, `indexOf("bc", 2)` ->
  `4`, `indexOf("bc", 5)` -> `7`, `indexOf("bc", 8)` -> `-1`, and a negative or
  over-length `fromIndex` behaves as clamped.
- **SC-002**: `zig build` and `zig build test` stay green.

# Spec 104: array lastIndexOf fromIndex

## Goal

Array `indexOf`/`includes` gained a `fromIndex` (spec 076); `lastIndexOf` was
left single-argument. This adds its optional `fromIndex` — the upper bound of a
backward search — matching JavaScript.

## Why additive, not breaking

Pure extension of the existing `lastIndexOf` array method: the single-argument
form is unchanged; a second integer argument bounds the search.

## API

Instance method on a `T[]` value:

- `lastIndexOf(x: T, from?: int): int` — index of the last element equal to `x`
  at or before `from` (default `length - 1`), or `-1`. Negative `from` counts
  from the end; values past the ends clamp.

## Requirements

- **FR-001**: Takes the element value, optionally followed by one integer; a
  non-integer `from` reports `E_TYPE_MISMATCH`, more than two arguments reports
  `E_ARG_COUNT`.
- **FR-002**: A negative `from` maps to `length + from`; the search considers
  only indices `<= from`, returning the greatest matching one or `-1`.
- **FR-003**: The single-argument form behaves exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `[10,20,30,20,10]`: `lastIndexOf(20)` -> `3`,
  `lastIndexOf(20, 2)` -> `1`, `lastIndexOf(20, 0)` -> `-1`,
  `lastIndexOf(10, -2)` -> `0`.
- **SC-002**: `zig build` and `zig build test` stay green.

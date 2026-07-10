# Spec 105: array fill

## Goal

`fill` sets a range of an array to a single value — the common way to build a
seeded array or reset a region. In Lumen's immutable model it returns a new
array rather than mutating the receiver.

## Why additive, not breaking

Pure addition to `arrayMethod`. It allocates a copy (like `with`/`concat`) and
overwrites the `[start, end)` range, leaving the source untouched.

## API

Instance method on a `T[]` value:

- `fill(value: T, start?: int, end?: int): T[]` — a copy of the array with
  indices in `[start, end)` set to `value`. `start` defaults to `0`, `end` to
  `length`. Negative bounds count from the end; both are clamped into
  `[0, length]`, and an empty range (`end <= start`) copies the array unchanged.

## Requirements

- **FR-001**: Requires a value assignable to the element type, optionally
  followed by up to two integer bounds; a mismatched value or non-integer bound
  reports `E_TYPE_MISMATCH`, zero or more than three arguments reports
  `E_ARG_COUNT`.
- **FR-002**: The result is a new array; the receiver is unchanged. Only the
  clamped `[start, end)` range takes `value`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `xs = [1,2,3,4,5]`: `xs.fill(0)` -> `[0,0,0,0,0]`,
  `xs.fill(9, 2)` -> `[1,2,9,9,9]`, `xs.fill(7, 1, 3)` -> `[1,7,7,4,5]`,
  `xs.fill(8, -2)` -> `[1,2,3,8,8]`, and `xs` still reads `[1,2,3,4,5]`.
- **SC-002**: `zig build` and `zig build test` stay green.

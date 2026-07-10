# Spec 092: array with (immutable index update)

## Goal

Arrays are immutable, so "change one element" meant rebuilding by hand. `with`
(ES2023) returns a copy with a single index replaced — the idiomatic immutable
update, fitting Lumen's array model exactly.

## Why additive, not breaking

Pure addition to `arrayMethod`. It allocates a fresh array (like `reverse`/
`concat`) and replaces one slot, leaving the source untouched.

## API

Instance method on a `T[]` value:

- `with(i: int, value: T): T[]` — a copy of the array with index `i` set to
  `value`. Negative `i` counts from the end. An index outside the array (after
  the negative adjustment) leaves the copy unchanged rather than trapping — a
  total, safe variant of JavaScript's throwing `with`.

## Requirements

- **FR-001**: `with` takes an integer index and a value assignable to the
  element type; a non-integer index or mismatched value reports
  `E_TYPE_MISMATCH`, and a wrong argument count reports `E_ARG_COUNT`.
- **FR-002**: The result is a new array; the receiver is unchanged.
- **FR-003**: A negative index maps to `length + i`; an index still outside
  `[0, length)` yields an unchanged copy.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `xs = [1,2,3,4]`: `xs.with(1, 99)` -> `[1,99,3,4]`,
  `xs.with(-1, 8)` -> `[1,2,3,8]`, `xs.with(10, 0)` -> `[1,2,3,4]`, and `xs`
  still reads `[1,2,3,4]` afterward.
- **SC-002**: `zig build` and `zig build test` stay green.

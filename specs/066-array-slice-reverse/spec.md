# Spec 066: array slice and reverse

## Goal

Arrays could be searched and folded but not re-shaped. `slice` (sub-array) and
`reverse` (order-flipped copy) are the two most common shape operations and
both fit the immutable-array model: neither mutates the receiver.

## Why additive, not breaking

Pure additions to `arrayMethod`. `slice` reuses the exact clamping used by
string `slice` (no negative-from-end indexing, per spec 014) and returns a
sub-slice of the existing backing storage. `reverse` allocates a fresh array so
the source stays untouched, matching how the language treats `T[]` as immutable.

## API

Instance methods on a `T[]` value:

- `slice(start?: int, end?: int): T[]` — elements in `[start, end)`, each
  endpoint clamped into `[0, length]`; empty when `start >= end`. With no
  arguments, copies the whole array.
- `reverse(): T[]` — a new array with the elements in reverse order; the
  receiver is unchanged.

## Requirements

- **FR-001**: `slice` accepts zero, one, or two integer arguments; a
  non-integer argument reports `E_TYPE_MISMATCH`, more than two reports
  `E_ARG_COUNT`. `reverse` takes no arguments.
- **FR-002**: `slice` endpoints are clamped into `[0, length]` and negative
  values clamp to `0` (no from-end indexing), consistent with string `slice`.
- **FR-003**: `reverse` does not mutate the receiver: a subsequent read of the
  original array sees the original order.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `xs = [1,2,3,4,5]`: `xs.reverse().join(",")` -> `5,4,3,2,1`,
  `xs.slice(1,3).join(",")` -> `2,3`, `xs.slice(3,1)` is empty, and `xs` still
  reads `1,2,3,4,5` afterward.
- **SC-002**: `zig build` and `zig build test` stay green.

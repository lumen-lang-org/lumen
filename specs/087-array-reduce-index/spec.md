# Spec 087: element index for reduce

## Goal

`reduce` was the last array callback method without access to the element index.
Specs 084-086 gave it to `map`/`forEach` and the predicate family; this adds the
optional third callback parameter to `reduce`, so a fold can weight elements by
position.

## Why additive, not breaking

Reuses the `cb_wants_index` mechanism. The reducer may now be `(U, T) => U` or
`(U, T, int) => U`; the two-parameter form is unchanged. The emitter forwards
the loop index only when the callback declares it.

## API

Instance method on a `T[]` value:

- `reduce(fn: (U, T) => U | (U, T, int) => U, init: U): U` — fold from `init`;
  the reducer receives the accumulator, the element, and (if declared) the
  element's integer index.

## Requirements

- **FR-001**: The reducer must take the accumulator and element, optionally
  followed by an integer index, and return the accumulator type; any other
  shape reports `E_TYPE_MISMATCH`. `reduce` itself requires exactly two
  arguments, else `E_ARG_COUNT`.
- **FR-002**: When the reducer declares the index it receives the zero-based
  position; the two-parameter form behaves exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `xs = [10,20,30,40]`:
  `xs.reduce((a, v) => a + v, 0)` -> `100`,
  `xs.reduce((a, v, i) => a + v * i, 0)` -> `200`,
  `xs.reduce((a, v, i) => a + v + i, 0)` -> `106`.
- **SC-002**: `zig build` and `zig build test` stay green.

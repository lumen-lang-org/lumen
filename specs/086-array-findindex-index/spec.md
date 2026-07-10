# Spec 086: element index for findIndex

## Goal

Specs 084 and 085 gave the element index to `map`/`forEach` and to
`filter`/`find`/`some`/`every`. `findIndex` was the last predicate method still
limited to a single-parameter callback; this brings it in line so every array
callback method accepts the optional index.

## Why additive, not breaking

Reuses the `cb_wants_index` mechanism. The predicate may now be `(T) => bool` or
`(T, int) => bool`; the single-parameter form is unchanged. `findIndex` already
iterates with the position in hand, so the emitter simply forwards it to the
callback when declared.

## API

Instance method on a `T[]` value:

- `findIndex(fn: (T) => bool | (T, int) => bool): int` — index of the first
  element for which the predicate holds, or `-1`.

## Requirements

- **FR-001**: The predicate must take one element-typed parameter, or two where
  the second is an integer index, and return `bool`; any other shape reports
  `E_TYPE_MISMATCH`. A wrong argument count reports `E_ARG_COUNT`.
- **FR-002**: When the predicate declares the index it receives the zero-based
  position; the one-parameter form behaves exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `xs = [10,20,30,40]`: `xs.findIndex(v => v > 25)` -> `2`,
  `xs.findIndex((v, i) => v > 0 && i >= 2)` -> `2`, and a never-true predicate
  -> `-1`.
- **SC-002**: `zig build` and `zig build test` stay green.

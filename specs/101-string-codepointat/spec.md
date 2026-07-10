# Spec 101: string codePointAt

## Goal

`codePointAt` is the JavaScript-idiomatic name for reading the numeric value of
the character at an index. In Lumen's byte-oriented string model it is
equivalent to `charCodeAt`, but supporting the name lets code written against
the modern API compile unchanged.

## Why additive, not breaking

`codePointAt` shares `charCodeAt`'s spec-table entry and lowering; nothing
existing changes.

## API

Instance method on a `string` value:

- `codePointAt(i: int): int` — the byte value at index `i`, or `-1` when out of
  range (consistent with `charCodeAt`).

## Requirements

- **FR-001**: Takes exactly one integer argument and returns `int`; a
  non-integer argument reports `E_TYPE_MISMATCH`, a wrong argument count reports
  `E_ARG_COUNT`.
- **FR-002**: Out-of-range indices yield `-1`, matching `charCodeAt`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `"ABC".codePointAt(0)` -> `65`, `"ABC".codePointAt(2)` -> `67`,
  `"ABC".codePointAt(5)` -> `-1`.
- **SC-002**: `zig build` and `zig build test` stay green.

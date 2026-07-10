# Spec 119: String.fromCodePoint

## Goal

`String.fromCodePoint` is the modern JavaScript name for building a string from
numeric character codes. In Lumen's byte-oriented model it is equivalent to the
variadic `String.fromCharCode` (spec 089); supporting the name lets modern code
compile unchanged.

## Why additive, not breaking

`fromCodePoint` shares `fromCharCode`'s checker branch and lowering; nothing
existing changes.

## API

- `String.fromCodePoint(...codes: int): string` — one byte per code, each masked
  to `code & 0xFF`, in order. At least one argument is required.

## Requirements

- **FR-001**: Requires one or more integer arguments; zero arguments reports
  `E_ARG_COUNT`, a non-integer argument reports `E_TYPE_MISMATCH`.
- **FR-002**: Behaves identically to `String.fromCharCode`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `String.fromCodePoint(72, 105)` -> `"Hi"`,
  `String.fromCodePoint(65)` -> `"A"`,
  `String.fromCodePoint(72, 101, 108, 108, 111)` -> `"Hello"`.
- **SC-002**: `zig build` and `zig build test` stay green.

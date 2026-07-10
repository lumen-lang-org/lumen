# Spec 089: variadic String.fromCharCode

## Goal

`String.fromCharCode` produced a single-character string. In JavaScript it takes
any number of codes and returns the string of all of them; building a multi-byte
string (e.g. from computed codes) shouldn't require concatenating single-char
calls.

## Why additive, not breaking

Pure relaxation of the existing `String.fromCharCode` argument rule: one
argument behaves exactly as before; additional integer arguments append more
bytes.

## API

- `String.fromCharCode(...codes: int): string` — one byte per code, each masked
  to `code & 0xFF`, in order. At least one argument is required.

## Requirements

- **FR-001**: `fromCharCode` requires one or more integer arguments; zero
  arguments reports `E_ARG_COUNT`, a non-integer argument reports
  `E_TYPE_MISMATCH`.
- **FR-002**: The result has one byte per argument, each `arg & 0xFF`, in
  argument order.
- **FR-003**: The single-argument form behaves exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `String.fromCharCode(72, 105)` -> `"Hi"`,
  `String.fromCharCode(72, 101, 108, 108, 111)` -> `"Hello"`,
  `String.fromCharCode(322)` -> `"B"` (`322 & 0xFF == 66`).
- **SC-002**: `zig build` and `zig build test` stay green.

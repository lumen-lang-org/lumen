# Spec 080: Number.parseInt / Number.parseFloat

## Goal

The language could format numbers but not parse them: turning user input or a
file field back into a number required dropping to raw handling. This adds a
`Number` static namespace with `parseInt` and `parseFloat`, returning an
optional so a failed parse is an explicit `null` rather than a silent `0` or a
trap.

## Why additive, not breaking

`Number` is a new static namespace registered alongside `Math`/`String`, so no
existing program changes. The optional result reuses the language's existing
`?` / `??` machinery.

## API

- `Number.parseInt(s: string, radix?: int): int | null` — parse the whole
  string as a signed 32-bit integer in `radix` (default `10`), or `null` if it
  is not a valid integer or overflows.
- `Number.parseFloat(s: string): f64 | null` — parse the whole string as a
  floating-point number, or `null` if it is not valid.

Parsing is strict: the entire string must be a valid number (unlike
JavaScript's lenient prefix parse). Consume the result with `?? default` or
null-narrowing.

## Requirements

- **FR-001**: `parseInt` takes a string and an optional integer radix;
  `parseFloat` takes a single string. A non-string input or non-integer radix
  reports `E_TYPE_MISMATCH`; a wrong argument count reports `E_ARG_COUNT`; an
  unknown `Number.*` name reports `E_UNSUPPORTED_STD`.
- **FR-002**: A string that does not fully parse (or overflows, for `parseInt`)
  yields `null`.
- **FR-003**: The result is `int | null` / `f64 | null` and interoperates with
  `??` and null-narrowing.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`, `E_UNSUPPORTED_STD`.

## Success Criteria

- **SC-001**: `Number.parseInt("42") ?? -1` -> `42`,
  `Number.parseInt("ff", 16) ?? -1` -> `255`,
  `Number.parseInt("12x") ?? -1` -> `-1`,
  `Number.parseFloat("3.14") ?? -1.0` -> `3.14`,
  `Number.parseFloat("xyz") ?? -1.0` -> `-1`.
- **SC-002**: `zig build` and `zig build test` stay green.

# Spec 108: number toString

## Goal

`toString` converts a number to its string form, and with a radix produces the
integer's representation in another base (hex, binary, octal, …) — the standard
way to format identifiers, flags, and encoded values.

## Why additive, not breaking

Pure addition to `numberInstanceMethod` (spec 107's numeric-receiver dispatch)
and the number-method emit branch; nothing existing changes.

## API

Instance method on any numeric value:

- `toString(): string` — the number in base 10 (works for `int` and `f64`).
- `toString(radix: int): string` — the *integer* receiver formatted in `radix`
  (2–36). A radix argument on a floating-point receiver is a type error.

## Requirements

- **FR-001**: `toString` takes zero or one argument; with an argument, both the
  radix and the receiver must be integers, else `E_TYPE_MISMATCH`; more than one
  argument reports `E_ARG_COUNT`.
- **FR-002**: The no-argument form is base-10 decimal for any number; the radix
  form uses `std.fmt.printInt` for lowercase base-N digits.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `(255).toString()` -> `"255"`, `(255).toString(16)` -> `"ff"`,
  `(255).toString(2)` -> `"11111111"`, `(255).toString(8)` -> `"377"`,
  `(3.5).toString()` -> `"3.5"`.
- **SC-002**: `zig build` and `zig build test` stay green.

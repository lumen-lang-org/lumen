# Spec 078: string padStart/padEnd default pad

## Goal

`padStart`/`padEnd` required an explicit pad string. In JavaScript the pad
defaults to a single space, which is the common case (right/left aligning to a
column). This makes the second argument optional, defaulting to `" "`.

## Why additive, not breaking

Pure extension of the existing `padStart`/`padEnd` string methods: the
two-argument form is unchanged; with one argument the pad string is `" "`.

## API

Instance methods on a `string` value:

- `padStart(len: int, pad?: string): string` — left-pad to `len` using `pad`
  (default `" "`).
- `padEnd(len: int, pad?: string): string` — right-pad to `len` using `pad`
  (default `" "`).

Both are a no-op when the string is already at least `len` long.

## Requirements

- **FR-001**: Each accepts one integer, optionally followed by one string; a
  non-integer length or non-string pad reports `E_TYPE_MISMATCH`, and zero or
  more than two arguments reports `E_ARG_COUNT`.
- **FR-002**: With one argument, the pad is a single space.
- **FR-003**: The two-argument form behaves exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `"5".padStart(3)` -> `"  5"`, `"5".padEnd(3)` -> `"5  "`,
  `"5".padStart(3, "0")` -> `"005"`, and `"hello".padStart(3)` -> `"hello"`.
- **SC-002**: `zig build` and `zig build test` stay green.

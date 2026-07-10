# Spec 079: string startsWith/endsWith position

## Goal

`startsWith`/`endsWith` could only test the very start or end of a string.
JavaScript lets `startsWith` begin at a position and `endsWith` treat the
string as if it ended at one; both are useful for scanning tokens mid-string.
This adds those optional position arguments.

## Why additive, not breaking

Pure extension of the existing `startsWith`/`endsWith` string methods: the
single-argument forms are unchanged; a second integer argument slices the
string before the check.

## API

Instance methods on a `string` value:

- `startsWith(prefix: string, pos?: int): bool` — whether the substring
  starting at `pos` (default `0`) begins with `prefix`.
- `endsWith(suffix: string, endPos?: int): bool` — whether the string truncated
  to `endPos` characters (default `length`) ends with `suffix`.

Both position arguments are clamped into `[0, length]`; negatives clamp to `0`.

## Requirements

- **FR-001**: Each accepts one string, optionally followed by one integer; a
  non-string needle or non-integer position reports `E_TYPE_MISMATCH`, and more
  than two arguments reports `E_ARG_COUNT`.
- **FR-002**: `startsWith` tests `s[pos..]`; `endsWith` tests `s[0..endPos]`,
  each with the position clamped into `[0, length]`.
- **FR-003**: The single-argument forms behave exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `"hello world"`: `startsWith("world", 6)` -> `true`,
  `startsWith("o", 4)` -> `true`, `endsWith("hello", 5)` -> `true`,
  `endsWith("world")` -> `true`.
- **SC-002**: `zig build` and `zig build test` stay green.

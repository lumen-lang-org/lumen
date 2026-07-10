# Spec 073: String.compare

## Goal

Array `sort` (spec 072) needs a comparator, but the language had no way to order
two strings — leaving `string[]` effectively unsortable. `String.compare`
provides the lexicographic byte ordering that closes that gap and doubles as a
general-purpose string ordering primitive.

## Why additive, not breaking

Pure addition to the `String` static namespace, alongside `contains` /
`startsWith`. It lowers to `std.mem.order` mapped to `-1 / 0 / 1`.

## API

- `String.compare(a: string, b: string): int` — `-1` if `a` sorts before `b`,
  `0` if equal, `1` if after, by unsigned byte order. A shorter string that is
  a prefix of the other sorts first.

## Requirements

- **FR-001**: `String.compare` takes exactly two `string` arguments and returns
  `int`; a non-string argument reports `E_TYPE_MISMATCH`, a wrong count reports
  `E_ARG_COUNT`.
- **FR-002**: The result is `-1`, `0`, or `1` following unsigned byte-wise
  lexicographic order.
- **FR-003**: The result is a valid `array.sort` comparator, so
  `arr.sort((a, b) => String.compare(a, b))` sorts a `string[]` ascending.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `String.compare("apple", "banana")` -> `-1`,
  `String.compare("cherry", "cherry")` -> `0`, `String.compare("ab", "abc")`
  -> `-1`; and `["banana","apple","cherry"].sort((a,b) => String.compare(a,b))`
  -> `apple,banana,cherry`.
- **SC-002**: `zig build` and `zig build test` stay green.

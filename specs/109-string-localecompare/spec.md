# Spec 109: string localeCompare

## Goal

`localeCompare` is the instance-method form of ordering two strings — the
idiomatic comparator for sorting a `string[]`
(`arr.sort((a, b) => a.localeCompare(b))`). It mirrors the existing
`String.compare` static, but as a method on the receiver.

## Why additive, not breaking

Pure addition to the `stringMethod` spec table and the string-method emit chain;
it lowers to `std.mem.order` mapped to `-1 / 0 / 1`, exactly like
`String.compare`.

## API

Instance method on a `string` value:

- `localeCompare(other: string): int` — `-1` if the receiver sorts before
  `other`, `0` if equal, `1` if after, by unsigned byte order.

## Requirements

- **FR-001**: Takes exactly one `string` argument and returns `int`; a
  non-string argument reports `E_TYPE_MISMATCH`, a wrong argument count reports
  `E_ARG_COUNT`.
- **FR-002**: The result is a valid `array.sort` comparator, so
  `arr.sort((a, b) => a.localeCompare(b))` sorts a `string[]` ascending.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `"apple".localeCompare("banana")` -> `-1`,
  `"cherry".localeCompare("cherry")` -> `0`, `"ab".localeCompare("abc")` ->
  `-1`; and `["banana","apple","cherry"].sort((a, b) => a.localeCompare(b))`
  -> `apple,banana,cherry`.
- **SC-002**: `zig build` and `zig build test` stay green.

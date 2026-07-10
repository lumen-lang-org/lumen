# Spec 083: Number infinity and MIN_VALUE constants

## Goal

Complete the `Number` constant set with the infinities and the smallest
positive value, so code can express saturating bounds and sentinel values
without constructing them arithmetically (which risks a compile-time
divide-by-zero).

## Why additive, not breaking

Pure additions to the zero-arg constant group in `numberCallType` and the
`Number.*` emit chain; nothing existing changes.

## API

- `Number.MIN_VALUE(): number` — the smallest positive representable `f64`
  (a denormal, ~5e-324).
- `Number.POSITIVE_INFINITY(): number` — positive infinity.
- `Number.NEGATIVE_INFINITY(): number` — negative infinity.

## Requirements

- **FR-001**: Each takes no arguments and returns `f64`; passing an argument
  reports `E_ARG_COUNT`.
- **FR-002**: The infinities interoperate with the numeric predicates:
  `Number.isFinite(Number.POSITIVE_INFINITY())` is `false`, and
  `Number.POSITIVE_INFINITY() > Number.MAX_VALUE()` is `true`.

### Diagnostics
Reuses `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Number.isFinite(Number.POSITIVE_INFINITY())` -> `false`,
  `Number.isFinite(Number.NEGATIVE_INFINITY())` -> `false`,
  `Number.POSITIVE_INFINITY() > Number.MAX_VALUE()` -> `true`,
  `Number.NEGATIVE_INFINITY() < 0.0` -> `true`, and `Number.MIN_VALUE()` prints
  a tiny positive value.
- **SC-002**: `zig build` and `zig build test` stay green.

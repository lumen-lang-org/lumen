# Spec 125: global Number(x) conversion

## Goal

`Number(x)` is JavaScript's global value-to-number conversion. Adding it gives a
uniform way to coerce a string, boolean, or number to a numeric value, with the
JavaScript convention that an unparseable string yields `NaN`.

## Why additive, not breaking

`Number(x)` is recognized as a conversion call (when no user function shadows
`Number`), separate from the `Number.*` static namespace, which is unchanged.
Codegen selects the coercion with a `@typeInfo` comptime branch.

While adding this, a latent label-collision bug in the `String`/`Boolean`/
`isNaN`/`isFinite` global emits (the unique-block counter was re-read after the
argument was emitted, so a nested global builtin shifted it) was fixed by
capturing the counter before emitting the argument. `isNaN(Number("abc"))` and
similar nestings now compile.

## API

- `Number(x: number | bool | string): number` — `f64`. Booleans map to `1`/`0`;
  numbers pass through; a string is parsed, yielding `NaN` if it is not a valid
  number.

## Requirements

- **FR-001**: Takes exactly one argument of numeric, boolean, or string type; an
  unsupported type reports `E_TYPE_MISMATCH`, a wrong count reports
  `E_ARG_COUNT`.
- **FR-002**: An unparseable string yields `NaN`; nested global conversions
  (e.g. `isNaN(Number("abc"))`) compile.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Number("3.14")` -> `3.14`, `Number(true)` -> `1`,
  `Number(false)` -> `0`, `isNaN(Number("abc"))` -> `true`,
  `Number("2.5") + 1.0` -> `3.5`.
- **SC-002**: `zig build` and `zig build test` stay green.

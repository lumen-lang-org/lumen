# Spec 122: global Infinity / NaN

## Goal

`Infinity` and `NaN` are global value constants in JavaScript, usable directly
(`const x = Infinity;`). Lumen recognized the `Number.*` function forms but not
the bare identifiers; this adds them.

## Why additive, not breaking

When an identifier resolves to no binding and no function, `Infinity` and `NaN`
are now recognized as `f64` constants (via a `builtin_const` Zig expression on
the var-ref node) lowering to `std.math.inf(f64)` / `std.math.nan(f64)`. A
local binding of the same name still shadows them (bindings are resolved first).

## API

- `Infinity: number` — positive infinity.
- `NaN: number` — not-a-number.

## Requirements

- **FR-001**: `Infinity` and `NaN` used as values have type `f64`.
- **FR-002**: A local/parameter binding named `Infinity`/`NaN` shadows the
  global constant.
- **FR-003**: They interoperate with the numeric predicates:
  `isFinite(Infinity)` is `false`, `isNaN(NaN)` is `true`.

## Success Criteria

- **SC-001**: `const x: f64 = Infinity; isFinite(x)` -> `false`;
  `Infinity > Number.MAX_VALUE()` -> `true`; `const y: f64 = NaN; isNaN(y)` ->
  `true`.
- **SC-002**: `zig build` and `zig build test` stay green.

# Spec 180: `Number.*` constants as properties

## Goal

Read the `Number` numeric constants as properties (no call parentheses),
matching JS and the existing `Math.PI` property form (spec from the Math
constants work):

```ts
Number.MAX_SAFE_INTEGER;    // 9007199254740991
Number.EPSILON;             // 2.220446049250313e-16
Number.POSITIVE_INFINITY;   // Infinity
Number.NaN;                 // NaN
```

Previously only the call form (`Number.EPSILON()`) worked; the bare property
reported `undefined variable 'Number'`.

## Why additive, not breaking

Only makes previously-rejected programs compile. The `Number.EPSILON()` call
form is unchanged, as are all other `Number.*` methods.

## Semantics

A `Number.<CONST>` field read (where `Number` is not a local binding) resolves
to an `f64` constant: `MAX_SAFE_INTEGER` (9007199254740991),
`MIN_SAFE_INTEGER`, `MAX_VALUE`, `MIN_VALUE`, `EPSILON`, `POSITIVE_INFINITY`,
`NEGATIVE_INFINITY`, and `NaN`. This mirrors the `Math.PI` property path.

## Requirements

- **FR-001**: `Number.<CONST>` reads as an `f64` for each listed constant.
- **FR-002**: The `Number.EPSILON()` call form and other `Number.*` methods are
  unchanged.

## Success Criteria

- **SC-001**: `Number.MAX_SAFE_INTEGER` -> `9007199254740991`;
  `Number.MIN_SAFE_INTEGER` -> `-9007199254740991`.
- **SC-002**: `Number.POSITIVE_INFINITY > big` is true; `Number.NEGATIVE_INFINITY
  < -big` is true.
- **SC-003**: `Number.NaN === Number.NaN` is false (NaN is unequal to itself).
- **SC-004**: `zig build` and `zig build test` stay green.

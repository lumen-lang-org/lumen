# Spec 134: Math.round half-rounding semantics

## Goal

Fix `Math.round` to match JavaScript, which rounds a value ending in `.5`
toward positive infinity (`floor(x + 0.5)`):

```ts
Math.round(-2.5)  // -2  (was -3)
Math.round(-0.5)  //  0  (was -1)
Math.round(2.5)   //  3  (unchanged)
```

Previously `round` lowered to Zig's `@round`, which rounds halves *away from
zero*, so negative halves came out one too low.

## Why a fix, not a feature

`Math.round` was emitting the wrong rounding rule for negative halves.
`floor`, `ceil`, and `trunc` were already correct and are unchanged.

## Semantics

`Math.round(x)` lowers to `floor(x + 0.5)`:

- A positive half rounds up (`2.5 -> 3`) — same as before.
- A negative half rounds toward zero / +Infinity (`-2.5 -> -2`, `-0.5 -> 0`).
- Non-half values round to the nearest integer as expected.

## Requirements

- **FR-001**: `Math.round` rounds `x.5` toward +Infinity, matching JS.
- **FR-002**: `Math.floor`, `Math.ceil`, `Math.trunc` are unchanged.

## Success Criteria

- **SC-001**: `Math.round(-2.5)` -> `-2`; `Math.round(-2.6)` -> `-3`;
  `Math.round(-2.4)` -> `-2`; `Math.round(2.5)` -> `3`;
  `Math.round(0.5)` -> `1`; `Math.round(-0.5)` -> `0`.
- **SC-002**: `Math.floor(-2.5)` -> `-3`; `Math.ceil(-2.5)` -> `-2`;
  `Math.trunc(-2.9)` -> `-2`.
- **SC-003**: `zig build` and `zig build test` stay green.

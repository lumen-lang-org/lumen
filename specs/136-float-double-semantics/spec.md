# Spec 136: float literals and division use f64 double semantics

## Goal

Make floating-point arithmetic match JavaScript's IEEE-754 double behavior in
two places that diverged:

```ts
0.1 + 0.2     // 0.30000000000000004  (was 0.3000...0004 with excess digits)
1.0 / 3.0     // 0.3333333333333333    (was 0)
```

## Two fixes

### 1. Float literals are `f64`, not `comptime_float`

A bare float literal lowered to Zig as a `comptime_float` (128-bit). A chain of
literal arithmetic then folded at 128-bit precision and printed extra digits.
Float literals now emit as `@as(f64, ...)` so arithmetic and formatting happen
at double precision, matching JS.

### 2. Float division keeps the fraction

The `/` operator lowered to `@divTrunc` for every operand type, truncating the
fraction of a float division (`1.0 / 3.0` -> `0`). Float division (result type
`f64`) now lowers to Zig's `/`. Integer division still truncates toward zero
(`@divTrunc`), which is Lumen's existing statically-typed integer semantics.

## Requirements

- **FR-001**: Float literals evaluate and print at f64 precision.
- **FR-002**: Division of float operands keeps the fractional result.
- **FR-003**: Integer division is unchanged (truncates toward zero).

## Success Criteria

- **SC-001**: `0.1 + 0.2` -> `0.30000000000000004`;
  `0.1 + 0.2 === 0.30000000000000004` -> `true`.
- **SC-002**: `1.0 / 3.0` -> `0.3333333333333333`; `10.0 / 4.0` -> `2.5`;
  a `f64`-typed `1.0 / 4.0` -> `0.25`.
- **SC-003**: `10 / 3` -> `3` (integer division unchanged).
- **SC-004**: `zig build` and `zig build test` stay green.

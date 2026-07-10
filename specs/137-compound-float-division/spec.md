# Spec 137: compound float division (/=)

## Goal

Fix the `/=` compound assignment so a float target keeps the fractional result,
matching plain float division (spec 136):

```ts
let x: f64 = 10.0;
x /= 4.0;   // 2.5  (was 2)
```

## Why a fix, not a feature

`/=` lowered to `@divTrunc` for every target type, truncating the fraction of a
float division. This is the same defect spec 136 fixed for the binary `/`
operator; the compound-assignment lowering was a separate code path that was
missed.

## Semantics

`x /= y` folds to `x = x / y`, using float division (Zig `/`) when `x` is `f64`
and truncating integer division (`@divTrunc`) otherwise — identical to the
binary `/` operator.

## Requirements

- **FR-001**: `/=` on an `f64` target keeps the fractional result.
- **FR-002**: `/=` on an integer target still truncates toward zero.

## Success Criteria

- **SC-001**: `let x: f64 = 10.0; x /= 4.0;` gives `x == 2.5`;
  `let z: f64 = 1.0; z /= 3.0;` gives `z == 0.3333333333333333`.
- **SC-002**: `let y: i32 = 10; y /= 3;` gives `y == 3`.
- **SC-003**: `zig build` and `zig build test` stay green.

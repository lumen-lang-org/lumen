# Spec 255: int/float arithmetic promotes; binary-op errors name the types

## Goal

Mixed numeric arithmetic works like TypeScript:

```ts
const half: f64 = n / 2.0        // i32 ÷ f64 → f64 (was: type mismatch)
const r: f64 = Math.round(f * 10.0) / 10.0
const mixed: f64 = n + 0.25
```

and a genuinely invalid operand pair explains itself:

```text
main.ts:3:7: error: operator '*' cannot combine `string` and `boolean`
```

## Semantics

- In `+ - * / % ** << >>`-family arithmetic (not bitwise/shift, which stay
  integer-only), an integer operand meeting an `f64` operand is promoted to
  `f64` through the runtime `Number()` conversion; the expression types as
  `f64`. Same-type arithmetic is unchanged.
- Non-numeric or otherwise incompatible operand pairs report the operator
  and both types in TS syntax instead of a bare "type mismatch".

## Success Criteria

- **SC-001**: `n / 2.0`, `1.5 * n`, `n + 0.25` compile and print the float
  results; `Math.round(x)/10.0` works.
- **SC-002**: `string * boolean` reports the named-operand message.
- **SC-003**: `zig build` and `zig build test` stay green.

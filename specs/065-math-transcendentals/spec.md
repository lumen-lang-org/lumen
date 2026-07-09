# Spec 065: Math transcendentals (tan, exp, log2, log10)

## Goal

`Math` already exposes `log`, `sin`, and `cos` as unary number->number
functions lowered to Zig float builtins. Four more equally common
transcendentals were missing and are direct siblings: `tan`, `exp`, `log2`,
`log10`. Each maps one-to-one to a Zig builtin (`@tan`, `@exp`, `@log2`,
`@log10`), so no new lowering machinery is needed.

## Why additive, not breaking

Pure additions to `mathCallType` and the `Math.*` emit chain; the new names
join the existing unary-f64 group and inherit its exact int->f64 argument
coercion and `f64` result.

## API

- `Math.tan(n: number): number`
- `Math.exp(n: number): number`
- `Math.log2(n: number): number`
- `Math.log10(n: number): number`

Integer arguments are coerced to `f64`, matching `sin`/`cos`/`log`.

## Requirements

- **FR-001**: Each function takes exactly one numeric argument and returns
  `f64`.
- **FR-002**: A non-numeric argument reports `E_TYPE_MISMATCH`; a wrong
  argument count reports `E_ARG_COUNT`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: A program computing `Math.exp(1)`, `Math.log2(8)`,
  `Math.log10(1000)`, `Math.tan(0)` compiles and prints the expected values
  (`2.718…`, `3`, `3`, `0`).
- **SC-002**: `zig build` and `zig build test` stay green.

# 417 — `bigint` type, `Nn` literals, and large integer literals

## Problem

Three related gaps around 64-bit integers:

```ts
let x: bigint = 100;      // error: expected `bigint`, got `i32`
let y = 100n;             // syntax error at `n`
let z = 9000000000;       // error: type 'i32' cannot represent 9000000000
```

- `bigint` had no type mapping, so it resolved to an unknown named type.
- The JS `BigInt` literal suffix `n` (`100n`) wasn't lexed.
- An integer literal too large for `i32` was rejected even though it fits `i64`.

## Approach

- **Type mapping** (`lumen_types.zig`, `fromAnnotation`): `bigint` resolves to
  `i64` — Lumen's 64-bit integer backs it (no arbitrary-precision type exists).
- **Lexer** (`lumen_lexer.zig`): accept and drop a trailing `n` on an integer
  literal; the value is already an `i64`, so `100n` lexes as `100`.
- **Inference** (`lumen_types.zig`, `inferExprType`): an integer literal outside
  the `i32` range (`> 2^31-1` or `< -2^31`) infers as `i64` instead of `i32`, so
  large literals (and `bigint` literals) aren't rejected as `i32` overflows.

## Verification

- `let x: bigint = 100n` / `= 100` / `= 9000000000` → all work.
- `bigint` arithmetic, parameters, arrays, and `bigint -> number` widening work.
- `5n * 3` → `15`; `9000000000` (unannotated) → `9000000000`.
- Small literals still infer `int` (`i32`); `int`-range arithmetic overflow
  (`2000000000 + 2000000000`) still reports the i32 overflow.
- Full `zig build` + test suite green.

## Notes

`bigint` is 64-bit, not arbitrary precision — values beyond `i64` overflow. An
unannotated small `Nn` literal (`5n`) infers `int` (it fits `i32`); annotate
`: bigint` to force `i64` when needed.

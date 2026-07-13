# Spec 434 — `BigInt(x)` conversion

## Problem

`bigint` literals (`100n`) and `bigint` arithmetic already worked, but the
`BigInt(x)` conversion function — needed to build a `bigint` from an ordinary
number, as in `f = f * BigInt(i)` — was unrecognized:

```
error: undefined variable 'BigInt'
```

## Change

`BigInt(x)` is accepted as a global conversion (alongside `Number`, `String`,
`Boolean`) when no user function shadows the name. The argument may be numeric,
`bool`, or `string`; the result type is `bigint` (`i64`). Codegen switches on the
argument's Zig type:

- `bool` → `1` / `0`,
- integer → widened to `i64`,
- float → truncated toward zero (`@intFromFloat(@trunc(x))`),
- string → `parseInt(i64, trim(x), 10)`, trapping on invalid input (JS `BigInt`
  throws a `SyntaxError` on an unparseable string).

## Verification

- `zig build` and `zig build test` clean.
- `let f: bigint = 1n; for (let i = 1; i <= 20; i++) f = f * BigInt(i)` →
  `2432902008176640000` (20!).
- `BigInt(42)` → `42`; `BigInt("1000000000000")` → `1000000000000`;
  `BigInt(3.9)` → `3`; `BigInt(true)` → `1`.

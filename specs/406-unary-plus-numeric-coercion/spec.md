# 406 — unary `+` coerces its operand to a number

## Problem

Unary plus was a pure parse-time no-op that returned its operand unchanged. On a
string operand this silently kept the string type, so numeric-looking code went
wrong instead of converting:

```ts
const s = "42";
const n = +s;        // n stayed `string`
console.log(n + 1);  // "421"  (string concat), should be 43
```

`+s` in JavaScript/TypeScript always produces a `number` (`+"42"` → `42`), so
treating it as identity broke the string case and let a `string` masquerade as a
number in inference.

## Approach

`lumen_parser_expr.zig`, `parseUnary`: lower `+x` to a `Number(x)` global call
instead of returning the operand directly. `Number(...)` already resolves to the
identity for a numeric operand and to a string→number conversion otherwise, so
both cases now have the correct `number` result type and runtime value.

## Verification

- `+"42"` → `42`; `+"42" + 1` → `43`; `+"10" * 2` → `20`.
- `let n: number = +s` (string) type-checks and yields `42`.
- Numeric operands unchanged: `+5 + 1` → `6`, `+x` (float `3.5`) → `3.5`.
- Full `zig build` + test suite green.

## Notes

`+x` now always has type `number` (`f64`), matching TypeScript, so an integer
operand promotes to `f64` — the intended meaning of an explicit numeric-coercion
operator.

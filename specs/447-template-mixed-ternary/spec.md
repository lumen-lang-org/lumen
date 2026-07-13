# Spec 447 — Mixed string/number ternary in a template hole

## Problem

A template interpolation whose expression is a ternary with a string branch and
a numeric (or bool) branch was rejected:

```ts
console.log(`${n < 0 ? "(" + Math.abs(n) + ")" : n}`); // error: expected string, got i32
```

The ternary's branches (`string` vs `i32`) couldn't unify to a single type, even
though every value stringifies inside a template.

## Change

In the template-hole checker (`lumen_check_expr.zig`), when a hole is a ternary
whose two branches are a string / stringifiable-non-string mix, the non-string
branch (numeric or bool) is wrapped in the runtime stringify conversion. Both
branches then have type `string`, so the ternary unifies and the hole checks as
`string`. The coercion is idempotent (once wrapped, both branches are strings, so
a re-check makes no further change).

Ternaries whose branches already share a type (two numbers, two strings) are
untouched.

## Verification

- `zig build` and `zig build test` clean.
- `` `${n < 0 ? "(" + Math.abs(n) + ")" : n}` `` → `(42)` for `n = -42`.
- `` `val: ${x > 0 ? x : "none"}` `` → `val: 5`.
- `` `${false ? "a" : 99}` `` → `99`; `` `${true ? 1 : 2}` `` → `1`.

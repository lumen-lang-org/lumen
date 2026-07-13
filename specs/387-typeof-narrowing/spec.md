# 387 — `typeof` narrowing and runtime `typeof` for nullable values

## Problem

`typeof x === "string"` did not narrow a `T | null` value, and — the root cause —
`typeof` of an optional folded to the compile-time constant `"undefined"`,
which is wrong (JS `typeof null` is `"object"`, and a non-null value has its
own typeof). So both the narrowing and the runtime value were incorrect:

```ts
function f(x: string | null): i32 {
  if (typeof x === "string") { return x.length; }  // x never narrowed
  return 0;
}
```

## Change

1. **Runtime typeof for optionals** (`lumen_check_expr.zig` + `lumen_emit.zig`):
   for a `T | null` operand, `typeof` is now a runtime value —
   `(x == null ? "object" : <inner typeof>)` — recorded via a new
   `typeof_expr.optional_runtime` flag and the inner type's typeof string.
   Non-optional operands keep their compile-time constant string.
2. **`typeof` narrowing** (`lumen_check.zig`, `narrowTarget`): a condition
   `typeof x === "string"` (or `"number"` / `"boolean"` / `"bigint"`) narrows
   `x` to non-null in the then-branch — `null`'s typeof is `"object"`, so a
   match rules it out. `typeof x !== "string"` narrows in the else/guard path.

## Verified

`zig build` + `zig build test` green. Probes (Node-parity where noted):

- `if (typeof x === "string") return x.length` → `f("hello")=5`, `f(null)=0`.
- `typeof x` on `i32 | null` → `number` / `object` (matches Node).
- `if (typeof x !== "string") return "was-null"; return x` → `hi` / `was-null`.
- Non-optional `typeof` (`typeof 5`, `typeof "s"`, `typeof true`) still
  compile-time constants.

## Boundary

Narrowing only removes `null` (the operand becomes its non-null type); it does
not split a genuine multi-type scalar union (those aren't supported anyway). The
compared string must be a non-null type name.

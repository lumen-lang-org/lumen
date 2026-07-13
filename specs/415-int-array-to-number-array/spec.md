# 415 — an `int[]` value widens to `number[]` at coercion points

## Problem

An inferred `int[]` (`i32[]`) value could not flow into a `number[]` (`f64[]`)
slot, even though TypeScript treats every numeric array as `number[]`. This was
the most frequent friction point from Lumen's integer-literal-defaults-to-`int`
inference:

```ts
const a = [1, 2, 3];              // inferred int[]
const b: number[] = a;            // error: expected `number[]`, got `i32[]`
new Set<number>(a);               // error
function sum(...n: number[]) {}
sum(...a);                        // error
const u = [...new Set<number>(a)]; // the array-unique idiom — error
```

Array-literal *elements* already widened in place; a whole `i32[]` *value*
(variable, parameter, method result) did not.

## Approach

Arrays are immutable, so converting an `i32[]` to an `f64[]` is a safe copy.

- **AST** (`lumen_ast.zig`): add an `int_array_to_float` flag on the cast node.
- **Check** (`lumen_check_assign.zig`): in the array-target branch of
  `ensureAssignable`, when a non-literal value of type `i32[]` flows into an
  `f64[]` slot, wrap it in an `int_array_to_float` cast (resolved type `f64[]`).
  This covers every coercion site — annotations, parameters, returns, object
  fields, `Set`/`Map` initializers.
- **Check idempotency** (`lumen_check_expr.zig`): `exprType` returns the cast's
  resolved `f64[]` directly for this flag, so a re-typed program (the checker may
  visit a node twice) doesn't re-validate the otherwise-disallowed
  `i32[] as f64[]` assertion.
- **Emit** (`lumen_emit.zig`): lower the cast to an elementwise
  `@floatFromInt` copy into a fresh `f64` slice.

## Verification

- `const b: number[] = a` (a: int[]) → `1,2,3`.
- `new Set<number>(a)` → size `3`; `[...new Set<number>(a)]` (unique) → `1,2,3`.
- `sum(...a)` into a `number[]` rest → `6`; `int[]` object field → `1,2,3`.
- `int[]` still infers `int[]` when unannotated (`let b = a`), and an element
  stays `int` (`a[0]` → `int`).
- Full `zig build` + test suite green.

## Notes

Only `i32[] -> f64[]` is widened (the `number[]` case). Deep/nested array
conversions and `i64[]` are out of scope. Resolves the recurring
integer-array-vs-`number[]` mismatch seen across probing (Set unions, rest
spreads, annotated bindings).

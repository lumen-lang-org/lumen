# 397 — `new Set<number>`/`new Map<K,number>` accept integer-literal initializers

## Problem

An `f64`-typed container built from integer literals was rejected:

```ts
new Set<number>([1, 2, 3]);              // error: type mismatch [E_TYPE_MISMATCH]
new Map<string, number>([["a", 1]]);     // error: type mismatch [E_TYPE_MISMATCH]
```

`number` resolves to `f64`, but the initializer `[1, 2, 3]` / `1` typed as `i32`.
The container checks compared the initializer's element type to the declared
element with strict `types.same`, which rejects the widening — even though
`let a: number[] = [1, 2, 3]` accepts exactly this via `ensureAssignable`'s
array-literal element widening. `Set<int>`, `Set<string>`, and inference-from-
initializer already worked; only the explicit-`f64`/`i64` case broke.

## Approach

`lumen_check_expr.zig`, the `new Set`/`new Map` container paths:

- **Set**: check the initializer against `arrayOf(T)` with `ensureAssignable`
  instead of comparing element types with `types.same`. This reuses the same
  integer-literal→`f64`/`i64` element widening as an annotated array, and
  rewrites the array node so emit produces the correct element type.
- **Map**: for each `[key, value]` entry (when K,V are declared, or after the
  first entry fixes an inferred K,V), check the key/value with
  `ensureAssignable(K, …)` / `ensureAssignable(V, …)` rather than `types.same`.

## Verification

- `new Set<number>([1,2,3]).has(2)` → `true`; dedup `size` of `[1,2,2,3]` → `3`.
- `new Map<string,number>([["a",1],["b",2]]).get("a")` → `1`.
- `Set<int>`, `Set<string>`, `Map<string,int>`, and inferred `new Map([["a",1]])`
  unchanged.
- Genuine mismatches now report a precise message
  (`expected \`string\`, got \`i32\``) instead of bare `E_TYPE_MISMATCH`.
- Full `zig build` + test suite green.

## Notes

Same numeric-literal-width family as spec 394 (reduce seed). Map-entry keys use
the same widening, so `Map<number, …>` integer keys are covered symmetrically.

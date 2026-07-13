# 414 — `...set` / `...string` spread into a type-annotated array

## Problem

Spreading a `Set` (or string) into an array worked when the array's type was
inferred, but failed when it was checked against an annotation or a `Set`/`Map`
constructor argument — the common set-union idiom:

```ts
const a = new Set<number>([1, 2]);
const b = new Set<number>([2, 3]);
const c: number[] = [...a, ...b];          // error: expected `number[]`, got `Set<number>`
const u = new Set<number>([...a, ...b]);   // error (constructor arg checked as number[])
```

The array-literal *inference* path (`exprType`) rewrites `...set` / `...str` to
`...Array.from(x)` so it contributes elements, but the *assignment-check* path
(`ensureAssignable`, used for annotations and `Set`/`Map` initializers via spec
397) checked each spread source directly against the array type — and a `Set` is
not an array.

## Approach

`lumen_check_assign.zig`, the array-target spread branch: mirror the inference
side. Resolve the spread source's type; if it is a `set_type` or string, rewrite
`item.spread` to `Array.from(source)` before checking it against the array type.
Array spreads are unchanged.

## Verification

- `const c: number[] = [...setA, ...setB]` → `1,2,2,3`.
- `new Set<number>([...a, ...b]).size` (set union) → `3`.
- String spread `const a: string[] = [...s]` → `a-b-c`.
- Mixed `[0, ...set, 9]` → `0,1,2,9`.
- Plain array spreads unchanged.
- Full `zig build` + test suite green.

## Notes

Completes the spec 397 Set/Map-initializer work: set-of-set unions now
type-check through the constructor.

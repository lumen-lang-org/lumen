# 404 — array-literal element inference mixes integer and float entries

## Problem

An un-annotated array literal mixing integer and float entries (directly or via a
spread) was rejected:

```ts
const a: number[] = [1.5];
const b = [...a, 2];   // error: type mismatch [E_TYPE_MISMATCH]
const c = [0, ...a];   // error
const d = [1, 2.5, 3]; // error
```

Element-type inference unified entries with strict `types.same`, so an `f64`
entry and an `i32` literal never agreed. Annotating the target (`const b:
number[] = …`) worked, because that path already widens through
`ensureAssignable`; only the inference path was strict.

## Approach

`lumen_check_expr.zig`, array-literal element inference:

1. When two entries disagree but are both numeric, unify at the wider type
   (`f64` > `i64` > `i32`) instead of failing.
2. After the element type is settled, if it is numeric, re-check each entry
   against it: non-spread items get their integer literals widened via
   `ensureAssignable`; a spread whose element type can't match (e.g. an `i32[]`
   spread into an inferred `f64[]`) is rejected with a clear type mismatch, since
   converting an already-typed array elementwise is not a cheap coercion.

## Verification

- `[...f64arr, 2]` → `1.5,2`; `[0, ...f64arr]` → `0,1.5`.
- Mixed literals `[1, 2.5, 3]` → `1,2.5,3`.
- Integer-only, float-only, and string arrays unchanged.
- `[...intArr, 1.5]` reports a type mismatch (documented limitation).
- Full `zig build` + test suite green.

## Notes

Same numeric-literal-width family as specs 394, 397, 402, 403. Widening an
already-typed integer array into a float array elementwise is intentionally out
of scope.

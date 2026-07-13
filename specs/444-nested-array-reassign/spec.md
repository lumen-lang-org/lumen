# Spec 444 — Reassigning / pushing an array-of-arrays literal

## Problem

`push` (spec 441) of an array or tuple element — and the underlying
`a = [...a, [x, y]]` reassignment it desugars to — failed on an
array-of-arrays or array-of-tuples target:

```ts
let grid: number[][] = [];
grid = [...grid, [1, 2]];               // error: type mismatch
function zip<A,B>(...): [A,B][] { let out: [A,B][] = []; out.push([a,b]); ... } // error
```

The declaration form (`const g: number[][] = [...a, [1,2]]`) worked, so the
inconsistency was surprising.

## Root cause

`number[][]` is `nested_array(f64_array)` but an integer element literal `[1,2]`
is `int[]` (`i32_array`). The declaration path checks the RHS through
`ensureAssignable`, which has the destination type and widens the inner array
element-wise. The assignment path first ran a *bare* `exprType` on the RHS to
compare types — with no destination context it couldn't widen the inner array
and reported a mismatch before `ensureAssignable` ever ran.

## Change

`nested_array` is added to the set of assignment target types
(`lumen_check_stmt.zig`) that skip the bare-`exprType` pre-check and go straight
to the final `ensureAssignable` — the same coercion path the declaration form
uses. Scalar-array targets keep the pre-check (their numeric widening already
works there).

## Verification

- `zig build` and `zig build test` clean.
- `grid = [...grid, [1,2]]` and a `push`-built 2-D grid work; `grid[2][2]`
  reads correctly.
- `zip(...)` accumulating `[A, B]` pairs with `out.push([a, b])` works.
- Scalar-array reassignment and int→number widening
  (`a = [...a, 4.5]` → `1,2,3,4.5`) and string arrays are unaffected.

# Spec 442 — `array.unshift` on a local array

## Problem

Following spec 441 (`push`), the companion prepend mutator `unshift` was still
rejected as an immutable-array operation, even though it desugars just as
cleanly.

## Change

The `expr_stmt` push desugar (`lumen_check_stmt.zig`) is generalized to also
handle `unshift`. A `push`/`unshift` statement on a plain local array variable
is rewritten to a reassignment:

- `a.push(x, y)`    → `a = [...a, x, y]`
- `a.unshift(x, y)` → `a = [x, y, ...a]`

Both reuse the immutable-append lowering (amortized-O(1) growable list in a loop)
and the same `let`-required diagnostic for a `const` target. Only the statement
form with a plain local-array receiver is rewritten.

## Verification

- `zig build` and `zig build test` clean.
- `let a: number[] = [1,2,3]; a.unshift(0)` → `[0,1,2,3]`;
  `a.unshift(-2,-1)` → `[-2,-1,0,1,2,3]`.
- Prepending in a loop (`for (const w of ...) q.unshift(w)`) reverses order as
  expected.
- `push` and `unshift` on the same array interoperate.

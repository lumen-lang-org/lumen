# 365 — Array-builder accumulator optimization (`a = [...a, x]`)

## Problem

Lumen arrays are immutable, so the compiler steers users to build arrays with
`a = [...a, x]` (the message `array.push` prints). But that idiom copied the
entire array every iteration — O(n²) for an n-element build. A 100k-element
loop took seconds.

The string-builder accumulator pass (a `let s = ""` only extended via
`s = s + ...` becomes a reused `ArrayList(u8)`) already solved the same shape
for strings. This extends it to arrays.

## Change

A behavior-preserving optimization — only speed changes, guarded by the same
conservative disqualification the string builder uses.

- **`lumen_ast.zig`**: `VarDecl.is_array_accumulator` and
  `Assign.is_array_accumulator`.
- **`lumen_opt.zig`** (`markAccumulators`): a `let a: T[] = []` that is mutable,
  reassigned, declared once, not a parameter, and only ever extended via
  `a = [...a, ...]` (checked by `accIsArrayAppend`: first element spreads `a`,
  `a` appears nowhere else) is marked an array accumulator. The disqualification
  walk (`accDisqStmt`) and the marking walk (`markAccStmt`) are parameterized by
  an `is_array` flag; the append predicate is the only branch that differs.
  Reads of `a` are tagged `is_accumulator` on the var-ref (shared with the
  string builder — both read as `.items`).
- **`lumen_emit_stmt.zig`**: an array-accumulator decl emits
  `var a: std.ArrayListUnmanaged(T) = .empty`; the `a = [...a, e1, e2, ...]`
  assignment emits an `append` per trailing element (`appendSlice` for a
  `...other` spread element) — amortized O(1) each.

### Incidental fix

`markAccStmt` and `accDisqStmt` did not traverse `ConsoleLog.extra_values`
(the args after the first in `console.log(a, b, c)`). This was a latent gap in
the string pass too — a read in a later arg was neither disqualified nor
rewritten. Both now walk `extra_values`.

## Verified

`zig build` + `zig build test` green. Probes (all correct):

- Basic build `for (…) a = [...a, i*i]`, `.length`, indexing `a[0]`, iteration,
  `.map(…).join(…)` after, multi-element append `[...a, i, i+100]`,
  string-element arrays, record-element arrays, conditional append, nested
  loops, build-and-return from a function.
- Disqualification: `a = [9]` (not an append) stays a normal slice assignment.
- `console.log(a[0], a[2])` (multi-arg) now reads `.items` correctly.

Perf: a 100k-element `a = [...a, i]` build now runs in ~3 ms (was O(n²), seconds).

## Boundary

Only the exact `a = [...a, …]` shape on a single-declaration, never-captured,
never-`Ref` local qualifies; anything else falls back to the immutable-slice
copy (correct, just not accelerated). `arr.push` is still not a method.

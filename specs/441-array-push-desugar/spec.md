# Spec 441 — `array.push` on a local array

## Problem

`array.push` — the single most common array idiom — was rejected outright
because Lumen arrays are immutable values. Canonical programs (FizzBuzz, building
a result list in a loop) failed:

```ts
let out: string[] = [];
out.push("Fizz");   // error: `array.push` is not supported
```

The suggested rewrite (`out = [...out, x]`) worked but is unidiomatic, and users
reach for `.push` first.

## Change

A `push` **statement** on a plain local array variable —
`a.push(x, y, ...)` where `a` is a `var_ref` to an array-typed binding — is
desugared in the checker (`lumen_check_stmt.zig`, `expr_stmt` arm) to the
equivalent reassignment `a = [...a, x, y, ...]`, then re-checked. This reuses the
existing immutable-append path, which the optimizer already turns into an
amortized-O(1) growable `ArrayList` when the appends happen in a loop — so
`push` in a loop is O(1) per call, not O(n).

Scope and diagnostics:

- Only a **statement** with a plain local-array receiver is rewritten. The
  length-returning expression form (`const n = a.push(x)`) is not, and a
  class-field or other receiver keeps the immutable-array guidance.
- Because `push` becomes a reassignment, the target must be `let`. A `const`
  array reports a clear message: *"`push` reassigns 'a' (arrays are immutable
  values in Lumen) — declare it with `let`, not `const`"*.
- Multi-argument `push(x, y)` appends each argument.

## Verification

- `zig build` and `zig build test` clean.
- FizzBuzz with `let out: string[] = []; out.push(...)` runs correctly.
- `let a: number[] = []; a.push(1); a.push(2, 3)` → `[1,2,3,4]`, length tracked;
  subsequent `map`/`filter`/index/`for…of` reads all work.
- Pushing record values and pushing inside a loop with a method-call argument
  (`names.push(w.toUpperCase())`) work.
- `push` on a function parameter array (`function f(a){ a.push(x); return a; }`)
  works.
- `const a: number[] = []; a.push(1)` reports the `let` guidance.

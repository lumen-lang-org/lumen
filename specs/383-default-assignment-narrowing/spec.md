# 383 — Default-assignment narrowing (`if (x == null) { x = … }`)

## Problem

The most common "supply a default" idiom didn't narrow the variable afterward:

```ts
function greet(name: string | null): string {
  if (name == null) { name = "World"; }
  return "Hi " + name;   // error: `string` + `string | null`
}
```

Early-return guards (`if (x == null) return …`) and `else` branches already
narrowed; the assign-and-fall-through form did not.

## Change

`lumen_check_stmt.zig`, the `if` handler: when the condition is `x == null`
(narrow target with `in_then = false`), there is no `else`, and the then-branch
falls through, narrow `x` to non-null for the rest of the block if the branch
assigns it a non-null default. `thenDefaultsNonNull` checks this soundly:

- requires a direct (top-level) `x = <expr>` whose value type is non-optional,
- with a plain `=` (a compound op like `+=` keeps the nullable type),
- and rejects any assignment to `x` nested inside a sub-block (which could set
  it back to null on a path not tracked here).

Composes with parameter reassignment (spec 382), so the pattern works on a
`T | null` parameter directly.

## Verified

`zig build` + `zig build test` green. Probes:

- `if (x == null) { x = 0; } return x` → `f(null)=0`, `f(5)=5`.
- `if (name == null) { name = "World"; } return "Hi " + name` → `Hi World` /
  `Hi Ann`.
- `if (x == null) { x = 99; } return x * 2` → `198` / `6`.
- Unsound cases stay rejected: a nested `if (…) { x = 0 }` and a compound
  `x += …` do not narrow.

## Boundary

Only the direct null-default shape narrows. General assignment-based
control-flow narrowing (tracking a variable's type across arbitrary
reassignments and branches) is still not modeled.

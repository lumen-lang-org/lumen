# 375 — `&&` conditions narrow the then-branch

## Problem

A null-check combined with another condition via `&&` did not narrow the
then-branch:

```ts
if (x != null && x > 0) { return x; }   // error: expected `i32`, got `i32 | null`
```

The `&&` right-operand narrowing (checking `x > 0` with `x` already non-null)
already worked, but `narrowTarget` — which drives the *then-branch* narrowing —
only recognized a bare `.cmp` condition, so a `bool_bin` `&&` condition narrowed
nothing in the body. This affected locals, record fields, and class fields
alike.

## Change

`lumen_check.zig`, `narrowTarget`: recurse into a `&&` (`bool_bin` with op
`"&&"`) — a `!= null` null-check in either operand holds in the then-branch
(both operands must be true to enter it), so its target is narrowed. Only
in-then narrowings propagate (an `&&` else-branch can't tell which operand was
false). Combines with spec 374's `this.x`/`c.x` path support.

## Verified

`zig build` + `zig build test` green. Probes:

- `if (x != null && x > 0) return x` (local) → `f(5)=5`, `f(-3)=0`.
- Same over a class field (`c.x`), `this.x`, and a record field (`p.x`) — all
  narrow and compile.

## Boundary

An `&&` chain with *two* null-checks feeding a later comparison
(`if (x != null && y != null && x > y)`) still fails: the condition-evaluation
narrowing tracks a single target at a time, so `y` is not yet narrowed when
`x > y` is checked. Bind one to a non-null local first, or nest the `if`s. Only
the single-null-check form is handled here.

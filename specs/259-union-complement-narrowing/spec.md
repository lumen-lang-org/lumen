# Spec 259: two-variant union narrowing in else and after early return

## Goal

The standard discriminated-union control-flow patterns type-check:

```ts
function area(s: Shape): f64 {
  if (s.kind == "circle") {
    return 3.14159 * s.r * s.r
  }
  return s.w * s.h            // s is Rect here (was: type mismatch)
}

if (r.kind == "err") {
  return "error: " + r.message
} else {
  return "value: " + String(r.value)   // r is Ok here
}
```

Previously only the then-branch narrowed; the else branch and the code
after an always-returning then-branch saw the unnarrowed union.

## Semantics

For a union with exactly two variants, a discriminant check narrows the
complement variant in the else branch, and — when the then-branch always
exits (returns/throws on every path) — for the rest of the enclosing block.
The block-scoped entry is cleared at block exit. Unions with 3+ variants
are unchanged (no unique complement).

## Success Criteria

- **SC-001**: Both patterns compile and run with correct output for both
  variants.
- **SC-002**: Then-branch narrowing and switch narrowing are unchanged;
  `zig build` and `zig build test` stay green.

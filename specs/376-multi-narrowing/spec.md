# 376 — Multi-target `&&` narrowing and `||` guard narrowing

Extends spec 375 (which handled a single null-check in an `&&`).

## Problem

Two common narrowing shapes still failed:

```ts
if (x != null && y != null) { return x + y; }   // only x was narrowed → error on y
if (x == null || y == null) { return -1; }
return x + y;                                    // x/y not narrowed after the || guard
```

## Change

A new checker helper `collectAndNullChecks(cond, wants_then)`
(`lumen_check.zig`) walks an `&&`/`||` operator chain and pushes *every*
matching null-check target onto the narrowed set, returning the count so the
caller can pop them.

- **Condition evaluation** (`lumen_check_expr.zig`, `bool_bin`): the right
  operand is checked with all of the left chain's null-checks narrowed, so
  `x != null && y != null && x > y` sees both non-null.
- **Then-branch** (`lumen_check_stmt.zig`, `if`): the body narrows every
  `&&`-chain null-check, not just the first.
- **`||` guard clause**: when the then-branch always exits, the complement of
  the whole `||` disjunction holds afterward, so every `== null` operand's
  target is non-null for the rest of the block.

## Verified

`zig build` + `zig build test` green. Probes:

- `if (x != null && y != null) return x + y` → `f(3,4)=7`, `f(3,null)=-1`.
- `if (x != null && y != null && x > y) return x` → `f(5,3)=5`, `f(2,9)=0`.
- `if (x == null || x < 0) return -1; return x` → `f(5)=5`, `f(-2)=-1`.
- `if (x == null || y == null) return -1; return x + y` → `f(3,4)=7`.
- Class/record fields (`c.a && c.b`), single-check `&&`, and simple `== null`
  guards all still work.

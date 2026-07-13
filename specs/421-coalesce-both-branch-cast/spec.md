# 421 — `??` casts both branches so `(a ?? "x").length` compiles

## Problem

Accessing a builtin field on a `??` result whose left side is a *method call*
(e.g. `Map.get`, `process.env`) failed to compile:

```ts
(m.get("a") ?? "x").length;      // backend: incompatible types '*const []const u8' and '*const *const [1:0]u8'
(process.env("PATH") ?? "") ...  // same
```

`l ?? r` emitted `if (l) |cv| @as(T, cv) else r` — only the *then* branch was
pinned to the result type. The *else* (a bare string literal) was left to
peer-resolve against `[]const u8`. In a context with a coercion target
(`console.log(...)`) Zig resolved it; but in `.length` field access (no target)
peer resolution produced a spurious pointer mismatch. A plain-variable left side
happened to resolve; a method-call left side did not.

## Approach

`lumen_emit.zig`, coalesce emit: wrap the else branch in `@as(T, …)` too, so both
branches are exactly the result type and no peer resolution is needed. The
result type is always set by the checker.

## Verification

- `(m.get("a") ?? "x").length` → `2`; `(process.env("PATH") ?? "none").length > 0`
  → `true`.
- Plain-variable coalesce `.length` still works (`2`).
- Numeric coalesce arithmetic `(m.get("a") ?? 0) + 1` → `6`.
- Chained `a ?? "d"`, `a ?? b ?? "d"`, `x ?? 0`, and `?.` unchanged.
- `(m.get("a") ?? "x").toUpperCase()` → `HI`.
- Full `zig build` + test suite green.

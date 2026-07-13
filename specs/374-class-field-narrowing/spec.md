# 374 — Null-narrowing works on class instance fields

## Problem

Narrowing an optional value with `!= null` worked for locals, parameters, and
record fields, but not for class instance fields:

```ts
class C { x?: i32; get(): i32 { if (this.x != null) { return this.x; } return -1; } }
// error: type mismatch: expected `i32`, got `i32 | null`
```

Two gaps:

1. The `.class_type` branch of field-read type resolution returned the field's
   declared type verbatim — it never consulted the narrowed set, unlike the
   `.named` (record) branch which unwraps a narrowed optional field.
2. `narrowPath` (which builds the narrow key for a field access) handled a
   `var_ref` base but not a `this_expr` base, so `this.x` produced no path — the
   narrowing was neither registered by the `if` nor found by the read.

## Change

`lumen_check_expr.zig`: the `.class_type` field read now mirrors the record
case — when the resolved field is optional and its path is narrowed, set
`field.unwrap` and read the inner type.

`lumen_check.zig`: `narrowPath` returns `"this"` for a `this_expr` base, so
`this.x` (and deeper `this.a.b`) form valid narrow keys.

## Verified

`zig build` + `zig build test` green. Probes:

- `if (this.x != null) return this.x` — compiles; unset instance → `-1`.
- After `setX(5)`, `this.x * 2` inside the guard → `10` (unwrapped to `i32`).
- `if (this.name != null) return "hi " + this.name` — `hi anon` when unset,
  `hi bob` when set.
- Field narrowing through a parameter (`c.x`, `c` a class instance) also works.
- Record-field and local narrowing unchanged.

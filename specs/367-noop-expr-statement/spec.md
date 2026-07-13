# 367 — No-op expression statements (fixes `Object.freeze(x)` as a statement)

## Problem

`Object.freeze(x)` is checked as an identity — records and arrays are already
immutable in Lumen, so the call is rewritten to its argument `x`. As a
statement, `Object.freeze(p);` therefore became a bare `p;`, which the emitter
lowered to `_ = p;`. Zig rejects that for a `const`:

```
error: pointless discard of local constant
```

## Change

`lumen_emit_stmt.zig`: an expression statement whose value is a bare variable
reference or literal (`var_ref`, `num`, `float`, `bool`, `str`, `null_lit`,
`this_expr`) is a no-op — emit nothing instead of `_ = <expr>;`. These have no
side effects, so dropping them is sound and matches JS (a bare `p;` does
nothing).

## Verified

`zig build` + `zig build test` green. Probes:

- `Object.freeze(p); console.log(p.x)` — compiles, prints the field.
- `Object.freeze(a)` on an array — compiles, array still usable.
- `const q = Object.freeze(p)` — inline use unchanged (still binds `p`).
- A bare `x;` statement compiles and is a no-op.

# 369 — Clean diagnostic for non-rewritable variant→union coercion

## Problem

Spec 358 coerces a variant-typed value to its discriminated union by rewriting
the value into an object literal of field reads — but only for a variable or
field path (cheap to re-emit). For any other expression the checker returned
"OK" *without* rewriting, so the backend received code it could not type:

```ts
const u: U = wrap(a);   // wrap(): A ; U = A | B
// -> Zig: expected type 'U', found 'A'  (backend error, not a Lumen diagnostic)
```

The checker accepted it, then the native backend failed — a miscompile surfaced
as an internal error instead of a clean message.

## Change

`lumen_check_assign.zig`: when a variant value assigned to its union is *not* a
variable or field path, fail with a clear diagnostic naming the workaround
(bind to a `const` first), instead of falling through to an accept that the
backend rejects.

## Verified

`zig build` + `zig build test` green.

- `const u: U = wrap(a)` now reports: *a `A` value coerces to `U` only from a
  variable or field — bind it to a `const` first*.
- The `const w = wrap(a); const u: U = w;` workaround type-checks cleanly.
- Direct variable / field coercion (spec 358) still works.

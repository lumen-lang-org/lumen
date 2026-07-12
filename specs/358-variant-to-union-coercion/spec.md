# 358 — Coerce a variant-typed value to its discriminated union

## Problem

A value already typed as a union's variant could not be used where the union
was expected, even though the checker accepted it:

```ts
type A = { kind: "a", x: i32 };
type B = { kind: "b", s: string };
type U = A | B;
function g(): U {
  const a: A = { kind: "a", x: 2 };
  return a;                    // Zig error: expected type 'U', found 'A'
}
```

Object *literals* worked (an anonymous Zig literal coerces into the union's
flat struct, whose fields all carry defaults), but a *named* variant value
emitted as-is — and Zig has no implicit struct-to-struct conversion. Failed at
the native-backend stage on `return a`, `f(a)` call args, and `const u: U = a`.
This is core discriminated-union usage.

## Change

`ensureAssignable`'s `.union_type` branch (`lumen_check_assign.zig`): when the
value's type is one of the union's variants and the value is a cheap
re-emittable source (a variable or field path), rewrite it into an object
literal of field reads (`{ kind: a.kind, x: a.x }`). The emitter's anonymous
literal then coerces into the flat union struct, with defaults filling the
other variants' fields — the same rewrite trick spec 278 uses for structural
width subtyping. `Checker.declFields` made pub for the variant field lookup.

## Verified

`zig build` + `zig build test` green. Probes (all print the expected value):

- `f(a)` / `f(b)` — variant values as union args, both variants.
- `return a` from a `(): U` function.
- `const u: U = a` — variant var init, then passed on as `U`.
- `f({ kind: "b", s: "lit" })` — literal path unchanged.
- Negative: `const u: U = c` where `C` is not a variant still fails
  `E_TYPE_MISMATCH`.

## Boundary

A variant value reached through a complex expression (a call result, a ternary)
is not rewritten — only variables and field paths, matching spec 278's "cheap,
re-emittable sources" rule, since each field read re-emits the source. Bind the
result to a `const` first.

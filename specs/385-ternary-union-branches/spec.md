# 385 — Ternary with different-variant branches coerces to the union

## Problem

Returning (or assigning) a ternary whose two branches are different variants of
a discriminated union failed:

```ts
function f(flag: bool): U {          // U = A | B
  const a: A = { … }; const b: B = { … };
  return flag ? a : b;               // error: expected `A`, got `B`
}
```

The ternary was type-checked without the expected union in context, so its two
branches (types `A` and `B`) had to match each other and didn't.

## Change

`lumen_check_assign.zig`, the `.union_type` case of `ensureAssignable`: when the
value is a ternary, check its condition is `bool` and each branch against the
*union* independently (each branch then coerces via the existing variant→union
path, spec 358). The ternary's `result_type` is set to the union so emission
casts both branches to the flat union struct.

## Verified

`zig build` + `zig build test` green. Probes:

- `return flag ? a : b` (a: A, b: B) → both variants flow to `U`; `f(true).k` =
  `a`, `f(false).k` = `b`.
- `const u: U = true ? a : b` — variable form.
- Regular same-type ternaries (`5 > 3 ? "y" : "n"`, `true ? 1 : 2`) unchanged.

## Boundary

Applies when the expected type is a discriminated union. A ternary in a context
with no expected union type still requires its branches to share a type.

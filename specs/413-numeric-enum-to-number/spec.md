# 413 — a numeric enum is assignable to `number`

## Problem

A numeric enum value coerced to `int` (`i32`) but not to `number` (`f64`):

```ts
enum Color { Red, Green }
const n: number = Color.Green;                 // error: expected `number`, got `Color`
function f(c: Color): number { return c; }     // error
```

`int` targets worked (spec 294 lowers a numeric enum to its `i32` backing), but
the `f64` assignment path only widened `isInteger` sources, and an `enum_type`
isn't one — so the JS rule that a numeric enum is assignable to `number` was
missing.

## Approach

`lumen_check_assign.zig`, the `.f64` target branch: extend the integer→`f64`
promotion (the `Number(x)` rewrite) to also fire when the source is a numeric
(non-string) enum. Numeric enums lower to an integer in the generated Zig, so
`Number(enumValue)` sees an integer and produces the `f64` — no emit change
needed.

## Verification

- `const n: number = Color.Green` → `1`.
- `function f(c: Color): number { return c; }` → `1`.
- Numeric enum into a `number[]` (`[Color.Red, Color.Blue]`) → `0,2`.
- Enum → `int` (`i32`) assignment unchanged.
- Full `zig build` + test suite green.

## Notes

Same numeric-promotion family as the integer→`f64` widening; string enums remain
assignable to `string` only.

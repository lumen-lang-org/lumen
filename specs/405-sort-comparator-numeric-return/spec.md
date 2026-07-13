# 405 — `sort`/`toSorted` comparator may return any number

## Problem

An array comparator that returned `f64` — the common `(a, b) => a.field - b.field`
over a `number` field, or a plain float array — was rejected:

```ts
const a: number[] = [3.5, 1.5, 2.5];
[...a].sort((x, y) => x - y);   // error: type mismatch [E_TYPE_MISMATCH]

type P = { age: number };
people.sort((x, y) => x.age - y.age); // error
```

The comparator was checked against a fixed `(elem, elem) => i32` signature. A
subtraction of two `f64` values yields `f64`, so the comparator's return type
never matched — even though JS only uses the comparator's *sign*.

## Approach

`lumen_check_methods.zig`, `sort`/`toSorted`: check the comparator with
`checkCbArg`, then accept it when it has exactly two parameters both equal to the
element type and a **numeric** return (`i32`, `i64`, or `f64`) — instead of
requiring the return to be exactly `i32`. The emitter already lowers the
comparator as `__cb.call(...) < 0`, which is sign-correct for any numeric return,
so no emit change is needed.

## Verification

- `[...f64arr].sort((x,y) => x - y)` → `1.5,2.5,3.5`.
- Sort records by an `f64` field (`(x,y) => x.age - y.age`) → ordered.
- Integer comparators, integer-field sorts, string-field sorts
  (`localeCompare`), and the no-argument default sort are unchanged.
- Full `zig build` + test suite green.

## Notes

Same numeric-literal/width family as specs 394, 397, 402–404. The comparator's
two parameters must both be the element type (distinct from the `(elem, index)`
callbacks used by `map`/`filter`).

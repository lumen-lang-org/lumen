# 354 — Infer generic type params through callback parameters and returns

## Problem

Generic functions that take a callback could not infer their type parameters
from the callback. Given

```ts
function apply<T, U>(x: T, f: (v: T) => U): U { return f(x); }
```

a call like `apply(5, (x) => x * 2)` failed with `E_TYPE_INFER`: the checker
never unified the function-type parameter annotation `(T) => U` against the
argument, so `U` stayed unknown, and the untyped arrow param `x` had no type.
Callers were forced to write explicit type args (`apply<i32, i32>(...)`) or
annotate every arrow parameter.

## Change

Two additions to `src/lumen_check_generics.zig`:

1. **`unifyAnnotation` function-type case.** When a parameter's annotation is a
   top-level function type (`(P, ...) => R`) and the argument's inferred type is
   a `func_type`, unify the return pattern `R` against the callback's return
   type and each parameter pattern `P` against the callback's parameter types.
   This infers a type parameter that appears only in a callback's return (`U`
   above is recovered from the arrow body's type).

2. **Arrow parameter hinting in `inferTypeArgs`.** When an argument is an untyped
   arrow bound to a function-typed parameter, resolve each of the parameter's
   type-pattern slots against the type params inferred from earlier arguments
   and set `arrow_param_hint` before checking the arrow. So in
   `apply(5, (x) => ...)`, `T` is first fixed to `i32` from the `5`, then `x` is
   hinted as `i32` — the arrow body checks without an annotation.

A helper `topLevelArrow(pattern)` finds a `=>` at paren/bracket/angle depth 0.
Function-type param annotations are stored as bare types (`(T)=>U`), so the
hint parser accepts both `T` and `name: T` slot forms.

## Verified

`zig build` + `zig build test` green. Runtime probe (parity with Node 22):

```ts
function apply<T, U>(x: T, f: (v: T) => U): U { return f(x); }
console.log(apply(5, (x) => x * 2));      // 10   — T,U inferred i32
console.log(apply(5, (x) => "n" + x));    // n5   — U inferred string
console.log(apply(3, (x: i32) => x + 1)); // 4    — annotated still works
```

Both emit `10 / n5 / 4`.

## Boundary

Inference resolves a callback param type from type params fixed by *earlier*
arguments. A type param that appears *only* inside the callback's parameter
position (never in a preceding value argument) still needs an explicit type
arg or an annotated arrow param.

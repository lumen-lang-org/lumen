# 423 — generic type inference through a tuple parameter

## Problem

A generic function with a tuple parameter couldn't infer its type parameters
from the argument:

```ts
function swap<A, B>(t: [A, B]): [B, A] { return [t[1], t[0]]; }
swap([1, "a"]);            // error: cannot infer type here [E_TYPE_INFER]
const arg: [number, string] = [1, "a"];
swap(arg);                 // also error
```

`unifyAnnotation` had no case for a tuple pattern (`[A, B]`), and a bare tuple
literal (`[1, "a"]`) can't self-type, so inference had nothing to unify.

## Approach

- **`unifyAnnotation`** (`lumen_check_generics.zig`): add a tuple-pattern case —
  a pattern that starts with `[` and ends with `]` (but isn't a `T[]` array)
  against a `tuple_type` argument unifies each comma-separated position against
  the tuple's positional element types (top-level-comma split with depth
  tracking).
- **`inferTypeArgs`**: when a tuple-typed parameter's argument is a bare array
  literal, type each element individually into a `tuple_type` before unifying,
  so a tuple *literal* argument infers too.

## Verification

- `swap([1, "a"])` → `a,1`; `fst([42, "x"])` → `42`; 3-tuple `mid([1,"x",true])`
  → `x`.
- Annotated tuple argument (`swap(arg)`) infers.
- Explicit type args, `T[]` array inference, and single-parameter inference
  unchanged.
- Full `zig build` + test suite green.

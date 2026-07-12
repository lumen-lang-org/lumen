# Spec 329 — Default, optional, and rest parameters on methods

## Goal

Let class methods (instance and static) use default, optional, and rest
parameters the same way free functions do:

```ts
class Calc {
  add(a: i32, b: i32 = 0): i32 { return a + b; }
  sum(...xs: i32[]): i32 { let t = 0; for (const x of xs) t = t + x; return t; }
}
const c = new Calc();
console.log(c.add(5));        // 5   (b defaults to 0)
console.log(c.sum(1, 2, 3));  // 6
```

## Motivation

Method calls checked argument count with a strict `args.len == params.len`, so a
call omitting a defaulted or optional parameter failed with
"expects N arguments, got M" — even though the same signature works on a free
function (which routes through the shared `checkCallArgs`).

## Behavior

Instance- and static-method calls now accept the same argument shapes as free
functions: trailing defaults may be omitted (and are filled in), optional (`x?:`)
parameters may be omitted (filled with `null`), and a rest parameter collects the
remaining arguments. Wrong argument counts still report a clear
"expects 1-2 arguments, got 0"-style message. A `spread` argument is only valid
into a rest parameter.

## Implementation

- `src/lumen_check_expr.zig`: both the instance-method and static-method call
  paths replace their ad-hoc count check and argument loop with a call to
  `checkCallArgs`, assigning the returned (default-filled) argument list back to
  the call node.

## Verification

- `zig build` and `zig build test` green.
- Instance and static methods with a default parameter, an optional parameter,
  and a rest parameter all run correctly; passing too few required arguments
  still errors clearly.

# Spec 331 — Spreading a tuple into fixed parameters

## Goal

Allow a fixed-length tuple to be spread into exactly-matching positional
parameters:

```ts
function add3(a: i32, b: i32, c: i32): i32 { return a + b + c; }
const args: [i32, i32, i32] = [1, 2, 3];
console.log(add3(...args));            // 6
console.log(add3(1, ...([2, 3] as [i32, i32])));  // 6
```

It works for free functions, methods, and constructors.

## Motivation

Spreading was only allowed into a rest parameter, so `add3(...args)` — a common
way to forward a fixed tuple — failed with
"spread argument only allowed for a rest parameter".

## Behavior

When an argument is a spread of a fixed-tuple value, it is expanded into one
positional argument per tuple element (`args[0]`, `args[1]`, …) before argument
checking. The expanded arguments must fill the callee's parameters exactly; a
tuple whose length does not match reports the normal argument-count error.
Non-tuple spreads (into a rest parameter) are unchanged.

## Implementation

- `src/lumen_check.zig`: `checkCallArgs` gains a pre-pass that detects a
  fixed-tuple spread, expands it into positional element-access expressions, and
  re-checks the call with the expanded argument list. Because the shared arg
  checker backs functions, methods, and constructors, all three support it.

## Verification

- `zig build` and `zig build test` green.
- A full-tuple spread and a mixed `f(x, ...tuple)` call run for a free function,
  a method, and a constructor; a wrong-length tuple reports the argument-count
  error; rest-parameter spreads are unaffected.

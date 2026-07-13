# 363 — `Map.forEach` accepts a value-only callback

## Problem

`Map.forEach` required a two-parameter `(value, key) => void` callback. The
JS/TS-idiomatic value-only form failed:

```ts
m.forEach(v => { ... })   // error: type mismatch [E_TYPE_MISMATCH]
```

The runtime `forEach` also always called the callback with two arguments, so
even a value-only closure would have mismatched the generated `.call` arity.

## Change

- **Checker** (`lumen_check_methods.zig`, `mapMethod`): the `forEach` callback
  may now have one parameter (the value) or two (value, key), validated via
  `checkCbArg` with `{value, key}` hints — same flexible-arity shape as
  `Array.forEach`.
- **Runtime** (`lumen_compiler.zig`, `LumenMap.forEach`): reflect on the
  callback's parameter count
  (`@typeInfo(@typeInfo(@TypeOf(cb.call)).pointer.child).@"fn".params.len`) and
  call with `(value, key)` for a two-param callback or `(value)` for a
  one-param callback.

`Set.forEach` was already single-parameter and is unchanged.

## Verified

`zig build` + `zig build test` green. Probes:

- `m.forEach(v => console.log(v))` over `{a:5, b:7}` prints `5` then `7`.
- `m.forEach((v, k) => console.log(k, v))` prints `a 5`.
- `s.forEach(v => console.log(v))` over a Set still prints its elements.

## Boundary

Mutating a captured outer variable inside the callback
(`m.forEach(v => { sum += v })`) is still rejected as `E_CAPTURED_MUTATION` —
use `for...of` or `reduce`, unchanged.

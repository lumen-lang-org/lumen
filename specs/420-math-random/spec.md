# 420 — `Math.random()`

## Problem

`Math.random()` — one of the most common standard-library calls — was
unsupported:

```ts
Math.random(); // error: unsupported standard-library call [E_UNSUPPORTED_STD]
```

## Approach

- **Check** (`lumen_check_stdlib.zig`, `mathCallType`): `random` takes no
  arguments and returns `number` (`f64`).
- **Runtime** (`lumen_compiler.zig` prelude): a lazily-seeded global PRNG
  (`std.Random.DefaultPrng`, seeded once from a stack address so the sequence
  varies run-to-run) exposed as `__mathRandom() f64`, returning a value in
  `[0, 1)`.
- **Emit** (`lumen_emit_static.zig`): `Math.random()` lowers to `__mathRandom()`.

The helper takes no `io` argument, so it works anywhere — including inside `map`
/ `filter` arrow callbacks (which don't receive the `io` plumbing).

## Verification

- `Math.random()` ∈ `[0, 1)`; two calls differ.
- Dice roll `Math.floor(Math.random()*6)+1` ∈ `[1, 6]`.
- Works inside a `map` callback.
- Distinct values across separate program runs (373385 / 258007 / 102383).
- `Math.random(5)` reports an arity error.
- Full `zig build` + test suite green.

## Notes

Not cryptographically secure (Xoshiro256, seeded from a stack address) — suitable
for games, sampling, and jitter, not secrets. Use `crypto` for secure randomness.

# Spec 258: lossless i32 → i64 widening

## Goal

```ts
function fib(n: i32): i64 {
  if (n < 2) return n          // i32 returns into i64 (was: type mismatch)
  return fib(n - 1) + fib(n - 2)
}
const big: i64 = 5000000000
console.log(big + small)       // i64 + i32 → i64
console.log(big > small)       // mixed comparison
acc += small                   // i64 += i32
```

## Semantics

An `i32` value flows into any `i64` context — assignments, returns,
arguments, arithmetic, comparisons, compound assignment — with no
conversion code (the emitted Zig widens implicitly). The reverse direction
(`i32 = i64`) is still a type error: narrowing is lossy.

## Success Criteria

- **SC-001**: `fib` and the mixed-width probes compile and print correct
  values.
- **SC-002**: Assigning i64 to an i32 slot still errors with expected/got.
- **SC-003**: `zig build` and `zig build test` stay green.

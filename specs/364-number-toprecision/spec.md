# 364 — `number.toPrecision(digits)`

## Problem

`toPrecision` was named in the number-method suggestion list but unimplemented,
producing a self-referential diagnostic:

```ts
(123.456).toPrecision(4)  // error: `number` has no method 'toPrecision' — did you mean 'toPrecision'?
```

## Change

- **Checker** (`lumen_check_methods.zig`, `numberInstanceMethod`): `toPrecision`
  takes one integer argument, returns `string`, sets `program.needs_to_precision`.
- **Runtime** (`lumen_compiler.zig`): gated helper `__numToPrecision(x, p)`
  implementing the ECMAScript algorithm — zero special-cased; exponential
  notation when `e < -6 || e >= p` (with JS `+` exponent sign), otherwise fixed
  with `p - 1 - e` fraction digits; negative sign preserved.
- **Emitter** (`lumen_emit.zig`): the `toPrecision` number-method call emits
  `__numToPrecision(<f64 receiver>, <usize digits>)`.

## Verified

`zig build` + `zig build test` green. Bit-identical to Node 22:

| call | Lumen / Node |
|---|---|
| `(123.456).toPrecision(4)` | `123.5` |
| `(123.456).toPrecision(2)` | `1.2e+2` |
| `(0.0001234).toPrecision(2)` | `0.00012` |
| `(-45.67).toPrecision(3)` | `-45.7` |
| `(0.0).toPrecision(3)` | `0.00` |

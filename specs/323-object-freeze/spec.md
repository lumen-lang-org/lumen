# Spec 323 — `Object.freeze` as an identity

## Goal

Accept `Object.freeze(x)`:

```ts
type P = { x: i32 };
const p: P = { x: 5 };
const q = Object.freeze(p);   // q: P
console.log(q.x);             // 5
```

## Motivation

`Object.freeze` is idiomatic for signalling immutability. Lumen records and
arrays are already immutable, so freezing is a no-op — but the call previously
errored with "only Object.keys is supported".

## Behavior

`Object.freeze(x)` returns `x` unchanged, keeping its type; the call is erased to
its argument at emit. It requires exactly one argument. Other `Object.*` methods
(besides `keys` and `freeze`) still report the unsupported message, now updated to
mention both.

## Implementation

- `src/lumen_check_expr.zig`: the `Object` namespace handler recognizes `freeze`,
  types its single argument, and replaces the call node with that argument.

## Verification

- `zig build` and `zig build test` green.
- `Object.freeze` over a record and an array run and preserve the value/type;
  a wrong argument count errors; unsupported `Object.*` methods still report the
  guidance.

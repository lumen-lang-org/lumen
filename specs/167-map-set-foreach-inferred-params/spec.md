# Spec 167: inferred params for Map/Set forEach callbacks

## Goal

Let `Map.forEach` and `Set.forEach` callbacks use untyped (inferred) parameters,
like array callbacks (spec 131):

```ts
map.forEach((v, k) => console.log(k, v));   // v: V, k: K inferred
set.forEach(x => console.log(x));           // x: T inferred
```

Previously these callbacks required explicit parameter types; untyped params
reported `E_TYPE_MISMATCH` (no inference context was supplied).

## Why additive, not breaking

Only makes previously-rejected programs compile. Typed callbacks are unchanged.

## Semantics

`Map.forEach`'s callback signature is `(value, key) => void` and `Set.forEach`'s
is `(value) => void`. The checker now publishes these parameter types as
inference hints (the same mechanism array methods use), so an untyped parameter
takes the expected type positionally.

## Requirements

- **FR-001**: `map.forEach((v, k) => ...)` infers `v: V`, `k: K`.
- **FR-002**: `set.forEach(x => ...)` infers `x: T`.
- **FR-003**: Explicitly typed callbacks are unchanged.

## Success Criteria

- **SC-001**: `new Map([["a",1],["b",2]]).forEach((v, k) => console.log(k, v))`
  prints `a 1` and `b 2`.
- **SC-002**: `new Set([10,20,30]).forEach(x => console.log(x))` prints
  `10`, `20`, `30`.
- **SC-003**: `zig build` and `zig build test` stay green.

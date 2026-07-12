# Spec 299: reduce with a record accumulator

## Goal

```ts
type Acc = { sum: i32, count: i32 };
const r: Acc = [10, 20, 30].reduce(
  (a: Acc, x: i32): Acc => ({ sum: a.sum + x, count: a.count + 1 }),
  { sum: 0, count: 0 }
);
```

Previously the object-literal seed (`{ sum: 0, count: 0 }`) failed with a
bare "type mismatch": a bare object literal can't self-infer a type, and
reduce derived the accumulator type from the seed.

## Semantics

When the reduce seed is an object literal and the callback is an annotated
arrow, the accumulator type is taken from the callback's first parameter
annotation and the seed is checked assignable against it. Scalar
accumulators (a seed that types on its own) are unchanged.

## Success Criteria

- **SC-001**: A record-accumulator reduce with an object-literal seed and an
  object-literal callback return compiles and computes correctly.
- **SC-002**: Scalar `reduce((a, x) => a + x, 0)` is unchanged.
- **SC-003**: `zig build` and `zig build test` stay green.

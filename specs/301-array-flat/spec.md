# Spec 301: Array.prototype.flat()

## Goal

```ts
const nested: i32[][] = [[1, 2], [3], [4, 5, 6]];
const flat: i32[] = nested.flat();   // [1,2,3,4,5,6]
```

Natural companion to nested arrays (spec 289) and `flatMap`. Previously
`.flat()` was an unknown method.

## Semantics

`.flat()` on a `T[][]` concatenates its inner arrays into a single `T[]`
(one level of flattening; no depth argument). On a non-array-of-arrays it
reports a tailored error naming the receiver type.

## Success Criteria

- **SC-001**: `flat()` on an `i32[][]` and a `string[][]` produces the
  concatenated single-level array in order.
- **SC-002**: `.flat()` on a plain array reports the "needs an array of
  arrays" error.
- **SC-003**: `zig build` and `zig build test` stay green.

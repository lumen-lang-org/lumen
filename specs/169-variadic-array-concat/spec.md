# Spec 169: variadic Array.concat

## Goal

Allow `Array.prototype.concat` to take several array arguments, as in
JavaScript:

```ts
[1, 2, 3].concat([4, 5], [6]);   // [1, 2, 3, 4, 5, 6]
["a"].concat(["b", "c"], ["d"]); // ['a', 'b', 'c', 'd']
```

Previously `concat` accepted exactly one array argument; extra arguments reported
`E_ARG_COUNT`.

## Why additive, not breaking

Only makes previously-rejected programs compile. Single-argument `concat` is
unchanged.

## Semantics

`arr.concat(a, b, ...)` returns a new array formed by appending every argument
array to the receiver, in order. Each argument must be an array of the same
element type. The source arrays are unchanged.

## Requirements

- **FR-001**: `concat` accepts one or more array arguments.
- **FR-002**: Each argument must be an array of the receiver's element type;
  otherwise `E_TYPE_MISMATCH`.
- **FR-003**: Single-argument `concat` is unchanged.

## Success Criteria

- **SC-001**: `[1,2,3].concat([4,5],[6])` -> `[1, 2, 3, 4, 5, 6]`.
- **SC-002**: `[1,2,3].concat([4,5])` -> `[1, 2, 3, 4, 5]` (single arg
  unchanged); empty-array arguments contribute nothing.
- **SC-003**: `["a"].concat(["b","c"],["d"])` -> `['a', 'b', 'c', 'd']`.
- **SC-004**: `zig build` and `zig build test` stay green.

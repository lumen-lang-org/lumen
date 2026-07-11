# Spec 187: `array.flatMap`

## Goal

Support `Array.prototype.flatMap`, mapping each element to an array and
concatenating the results into one flat array:

```ts
[1, 2, 3].flatMap(x => [x, x * 10]);   // [1, 10, 2, 20, 3, 30]
["a", "b"].flatMap(s => [s, s + "!"]); // ["a", "a!", "b", "b!"]
```

Previously unsupported (`E_TYPE_MISMATCH`). Enabled now that a spread-free array
literal returned from the callback heap-allocates and escapes safely (spec 186).

## Why additive, not breaking

`flatMap` was previously unavailable; adding it only makes more programs compile.

## Semantics

`a.flatMap(cb)` calls `cb` on each element (with an optional `i32` index second
parameter), each call returning an array; the arrays are concatenated in order
into a single flat `U[]`, where `U` is the callback array's element type. The
result is always one level deep — flatMap does not produce nested arrays.

## Implementation

- Checker: the callback is typed `(T[, i32]) => U[]` via `checkCbArg`; the
  callback return type must be an array, and the result is that array type.
- Emit: iterate the receiver, and `appendSlice` each `cb.call(...)` result into a
  growing result list.

## Limitations

An empty array literal `[]` still cannot be inferred on its own, so the
`flatMap(x => cond ? [x] : [])` filter idiom does not type-check (the `[]`
branch has no element type). Use a non-empty array in both ternary branches, or
`filter` then `flatMap`.

## Requirements

- **FR-001**: `a.flatMap(x => arr)` concatenates each callback array in order.
- **FR-002**: A `(x, i)` callback receives the `i32` index.
- **FR-003**: The callback array may contain spreads.

## Success Criteria

- **SC-001**: `[1,2,3].flatMap(x=>[x,x*10])` -> `[1,10,2,20,3,30]`.
- **SC-002**: `[1,2].flatMap((x,i)=>[x,i])` -> `[1,0,2,1]`.
- **SC-003**: `["a","b"].flatMap(s=>[s,s+"!"])` -> `["a","a!","b","b!"]`.
- **SC-004**: `zig build` and `zig build test` stay green.

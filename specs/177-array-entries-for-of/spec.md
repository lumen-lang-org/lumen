# Spec 177: `for (const [i, v] of arr.entries())`

## Goal

Support index/value destructuring over an array in a for-of loop, the standard
enumerate idiom:

```ts
const words = ["a", "b", "c"];
for (const [i, w] of words.entries()) {
  console.log(i, w);   // 0 a / 1 b / 2 c
}
```

Previously `arr.entries()` in a for-of reported `E_TYPE_MISMATCH` — the only
way to get an index was a manual counter or `forEach((v, i) => ...)`.

## Why additive, not breaking

Only makes previously-rejected programs compile. `for (const [k, v] of map)`
(Map pair iteration) and plain `for (const v of arr)` are unchanged.

## Semantics

`for (const [i, v] of arr.entries())` binds `i` to the running index (`i32`,
starting at 0) and `v` to the element at that index, iterating in order. The
iterable is the receiver array; `.entries()` exists only as a for-of iterable
(not a standalone array method). A `_` binding for either slot is allowed.

## Implementation

- Checker: a pair for-of whose iterable is a zero-arg `.entries()` method call on
  an array is detected before generic iterable inference, rewrites the iterable
  to the receiver, binds the index as `i32` and the value as the element type,
  and sets `is_array_entries`.
- Emit: `is_array_entries` emits an indexed `while` over the receiver slice,
  binding the `i32` index and the element each iteration. The Map pair branch is
  guarded off for this case.

`map.entries()` is accepted too: it is the map itself as a key/value iterable,
so it rewrites to the receiver and iterates like `for (const [k, v] of map)`.

## Requirements

- **FR-001**: `for (const [i, v] of arr.entries())` binds `i: i32` and `v: T`.
- **FR-002**: Works for an array variable and an array literal receiver.
- **FR-003**: Map pair iteration and plain array for-of are unchanged.
- **FR-004**: `for (const [k, v] of map.entries())` iterates the map.

## Success Criteria

- **SC-001**: `["x","y","z"].entries()` yields `(0,x) (1,y) (2,z)`.
- **SC-002**: `[10,20,30].entries()` — `i + ":" + v` gives `0:10 1:20 2:30`.
- **SC-003**: `for (const [_, v] of a.entries())` binds only the value.
- **SC-004**: `for (const [k, v] of map)` still iterates the map.
- **SC-005**: `zig build` and `zig build test` stay green.

# Spec 184: `Array.from(src, mapFn)`

## Goal

Support the two-argument `Array.from` with a map callback, a common
build-and-transform idiom:

```ts
Array.from([1, 2, 3], x => x * 2);          // [2, 4, 6]
Array.from("abc", c => c.toUpperCase());    // ["A", "B", "C"]
Array.from([10, 20, 30], (x, i) => x + i);  // [10, 21, 32]
```

Previously only the single-argument form was accepted (`E_ARG_COUNT`).

## Why additive, not breaking

Only makes previously-rejected programs compile. The single-argument
`Array.from(x)` (string chars, array copy, Set elements) is unchanged.

## Semantics

`Array.from(src, cb)` maps each element of `src` through `cb`, returning a new
array of the callback's return type. The source may be a string (elements are
single-character strings), an array, or a `Set`. The callback is `(v) => u` or
`(v, i) => u`, where `i` is the element index (`i32`); the result is `u[]`.

## Implementation

- Checker: the two-argument `from` derives the source element type (single-char
  string / array element / set element), types the callback via `checkCbArg`
  with `(elem, i32)` hints, records `cb_wants_index`, and returns `u[]`.
- Emit: builds the source slice (chars array / the array / `set.values()`),
  binds the closure, and maps each element through `__cb.call(__cb.ctx, e[, i])`
  into the result array — the same closure-call shape as `array.map`.

## Requirements

- **FR-001**: `Array.from(arr, cb)` maps the array; `Array.from(str, cb)` maps
  each character; `Array.from(set, cb)` maps each element.
- **FR-002**: A `(v, i)` callback receives the `i32` index.
- **FR-003**: The single-argument `Array.from(x)` forms are unchanged.

## Success Criteria

- **SC-001**: `Array.from([1,2,3], x=>x*2)` -> `[2,4,6]`;
  `Array.from("abc", c=>c.toUpperCase())` -> `["A","B","C"]`.
- **SC-002**: `Array.from([10,20,30], (x,i)=>x+i)` -> `[10,21,32]`;
  `Array.from("abc", (c,i)=>c+i)` -> `["a0","b1","c2"]`.
- **SC-003**: `Array.from(new Set([1,2,3]), x=>x*x)` -> `[1,4,9]`.
- **SC-004**: `zig build` and `zig build test` stay green.

# Spec 154: console.log of arrays

## Goal

Let `console.log` print an array, like JavaScript, instead of failing to build:

```ts
console.log([1, 2, 3]);        // [1, 2, 3]
console.log(["a", "b", "c"]);  // ['a', 'b', 'c']
console.log(nums.map(x => x * 2));
```

Previously `console.log` of an array-typed value produced a format spec (`{d}`)
that could not format a slice, so the generated Zig failed to build.

## Why additive, not breaking

Only makes previously-broken programs compile. Scalar `console.log` is
unchanged.

## Semantics

`console.log(arr)` (and `.info`/`.debug`/`.error`/`.warn`/`.trace`) renders the
array with a runtime formatter: `[` + each element joined by `, ` + `]`. Numeric
and boolean elements print with their normal format; string elements are quoted
with single quotes (`['a', 'b']`), matching Node. A bare array-literal argument
is wrapped in a real slice first (it otherwise emits as a tuple).

## Requirements

- **FR-001**: `console.log` of an array prints `[e0, e1, ...]`.
- **FR-002**: String elements are single-quoted; numbers and booleans print
  normally.
- **FR-003**: Both an array variable and an array-producing expression
  (`arr.map(...)`) work; a bare array literal works.
- **FR-004**: Scalar `console.log` is unchanged.

## Success Criteria

- **SC-001**: `console.log([1,2,3])` -> `[1, 2, 3]`;
  `console.log(["a","b","c"])` -> `['a', 'b', 'c']`;
  `console.log([true,false])` -> `[true, false]`.
- **SC-002**: `console.log(nums.map(x => x * 2))` prints the mapped array.
- **SC-003**: `console.log(42)` and `console.log("s")` still work.
- **SC-004**: `zig build` and `zig build test` stay green.

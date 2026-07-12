# Spec 353 — `new Array<T>(n).fill(v)` with an element type argument

## Goal

Accept an element type argument on the sized-array constructor:

```ts
const zeros = new Array<i32>(5).fill(0);      // [0,0,0,0,0]
const dashes = new Array<string>(3).fill("-");
```

## Motivation

`new Array(n).fill(v)` (a fused sized-array initializer) worked, but adding the
idiomatic element type argument `new Array<i32>(n)` was rejected with
`wrong number of type arguments`, because the fused path required exactly zero
type arguments.

## Behavior

The sized-array `new Array(...).fill(...)` initializer accepts an optional single
element type argument (the element type is already determined by the `fill`
value, so the argument is documentary). No-type-argument `new Array(n).fill(v)`
is unchanged.

## Implementation

- `src/lumen_check_expr.zig`: the `new Array(n).fill(v)` recognition allows up to
  one type argument on the `new Array<...>` receiver.

## Verification

- `zig build` and `zig build test` green.
- `new Array<i32>(5).fill(0)` and `new Array<string>(3).fill("x")` build sized
  arrays with the right length and element; the untyped form is unchanged.

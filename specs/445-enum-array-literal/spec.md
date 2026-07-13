# Spec 445 — Array literal of enum members

## Problem

An array literal of enum members was rejected:

```ts
enum Status { Active, Inactive, Pending }
const all = [Status.Active, Status.Inactive, Status.Pending]; // error: type mismatch
```

The array-literal checker could build arrays of scalars, records, and arrays,
but had no case for an element whose type is an enum, so it fell through to
`E_TYPE_MISMATCH`.

## Change

In the array-literal result-type computation (`lumen_check_expr.zig`), an enum
element type is boxed into a `nested_array` (heap-allocated inner `Type`),
alongside the existing array-of-arrays case. The element type stays the enum
(`Status`), so `for…of` bindings and function calls keep the enum type, while
the array lowers to the enum's backing representation (`[]i32` for a numeric
enum, `[]const u8` for a string enum).

## Verification

- `zig build` and `zig build test` clean.
- `[Status.Active, Status.Inactive, Status.Pending]` builds a `Status[]`;
  iterating it and calling an enum-typed function on each element works.
- String-enum arrays (`[Dir.Up, Dir.Down]`) iterate and print their string
  values.
- Pushing enum members (`let seq: Dir[] = []; seq.push(Dir.Up)`) works.
- Enum-array `filter` / `map` / `indexOf` / `includes` all work.

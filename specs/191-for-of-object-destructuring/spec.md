# Spec 191: `for (const { … } of records)`

## Goal

Support object-pattern destructuring in a for-of loop, the natural way to
iterate an array of records:

```ts
interface Point { x: i32; y: i32; }
const pts: Point[] = [{ x: 1, y: 2 }, { x: 3, y: 4 }];
for (const { x, y } of pts) {
  console.log(x + y);   // 3 / 7
}
```

Previously this was a syntax error; a plain binding or `[k, v]` pair was the only
option.

## Why additive, not breaking

Only makes previously-rejected programs compile. Plain for-of, `[k, v]` Map pair
iteration, and `arr.entries()` iteration are unchanged.

## Semantics

`for (const { f1, f2 } of xs)` iterates `xs`, binding each named field of the
current element (a record) in the loop body. It is exactly equivalent to
`for (const __t of xs) { const { f1, f2 } = __t; … }`.

## Implementation

- Parser: an object pattern after `for (const` is desugared to a plain for-of
  over a fresh temporary with an object destructuring of that temporary
  prepended to the loop body — reusing the existing object-destructuring and
  for-of paths, so no new checker or emit code is needed.

## Requirements

- **FR-001**: `for (const { f } of xs)` binds field `f` of each record element.
- **FR-002**: Multiple fields and a block body are supported.
- **FR-003**: Plain, `[k, v]` pair, and `.entries()` for-of are unchanged.

## Success Criteria

- **SC-001**: `for (const { n } of ps)` over `[{n:1},{n:2},{n:3}]` prints
  `1 2 3`.
- **SC-002**: `for (const { x, y } of pts)` binds both fields.
- **SC-003**: `for (const x of [1,2,3])` and `for (const [k,v] of map)` still
  work.
- **SC-004**: `zig build` and `zig build test` stay green.

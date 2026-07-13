# 418 — nested array-method calls no longer collide on block locals

## Problem

Any array higher-order method nested inside another's callback failed to
compile — the extremely common grid/matrix pattern:

```ts
const grid = [[1, 2], [3, 4]];
grid.map(row => row.reduce((a, b) => a + b, 0));
// backend: local constant '__arr' shadows local constant from outer scope
```

Each array-method block binds fixed locals (`__arr`, `__cb`, `__r`, `__acc`,
`__e`, `__i`, …). When one method's block is emitted lexically inside another's
callback, the inner `const __arr` shadows the outer `const __arr`, and Zig
forbids shadowing an enclosing-scope local. Only the block *label* (`__am{seq}`)
was unique; the locals were not.

## Approach

`lumen_emit_array_string.zig`: after an array-method block is emitted, suffix its
own block-scoped locals with the block's unique sequence number
(`suffixArrayLocals`, hooked via `defer`). Because emission is inner-first, a
nested block is already suffixed (e.g. `__arr2`) by the time the outer block is
renamed; the rename skips any name already followed by a digit, so it only
touches the outer block's own bare locals. The set of renamed names is the
curated list of block-scoped locals (`ARRAY_METHOD_LOCALS`); loop-capture and
callback-internal identifiers are handled consistently within each block.

## Verification

- `grid.map(row => row.reduce((a,b)=>a+b, 0))` → `3,7`.
- `map`+`map`, `reduce`+`reduce`, `filter`+`map`, `map`+`join`, `map`+`includes`,
  `map`+`sort` nestings all compile and run.
- Deep `map(filter().reduce())` and triple-nested `map(map(reduce()))` work.
- Flat and chained (`filter().map().join()`) calls unchanged.
- Full `zig build` + test suite green.

## Notes

The rename is scoped to `emitArrayMethod` output and keyed on each block's unique
`g_array_method_seq`, so inner and outer blocks never share a local name.

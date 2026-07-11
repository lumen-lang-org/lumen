# Spec 192: spreading a Set into an array literal

## Goal

Support `[...set]`, most importantly the canonical dedup idiom:

```ts
const uniq = [...new Set(nums)];        // deduplicated array
const sorted = [...set].slice().sort();
[1, ...set, 4];                          // interleaved
```

Previously a Set spread in an array literal reported `E_TYPE_MISMATCH` (only
array sources were allowed); `Array.from(set)` was the only conversion.

## Why additive, not breaking

Only makes previously-rejected programs compile. Spreading an array is unchanged.

## Semantics

`[...set]` contributes the Set's elements (in insertion order) to the array,
with the Set's element type. It composes with other entries and spreads
(`[1, ...set, 4]`). Implemented by rewriting the Set spread source to
`Array.from(set)` during checking, so it flows through the existing array-spread
path (which emits the Set's values slice).

## Requirements

- **FR-001**: `[...set]` yields the Set's elements as an array of its element
  type.
- **FR-002**: Composes with plain entries and array spreads in the same literal.
- **FR-003**: Array spreads are unchanged.

## Success Criteria

- **SC-001**: `[...new Set([1,2,2,3,3,3])]` -> `[1,2,3]` (dedup).
- **SC-002**: `[1, ...new Set([2,3]), 4]` -> `[1,2,3,4]`.
- **SC-003**: `[...set].slice().sort((x,y)=>x-y)` sorts the elements.
- **SC-004**: `zig build` and `zig build test` stay green.

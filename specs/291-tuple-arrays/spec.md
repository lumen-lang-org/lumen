# Spec 291: arrays of tuples

## Goal

```ts
const pairs: [i32, string][] = [[1, "one"], [2, "two"]];
for (const [key, val] of pairs) { ... }   // destructures each pair
pairs[1][1];                               // indexes both levels
const m: Map<string, i32> = new Map<string, i32>();
for (const [k, v] of entries) { m.set(k, v); }
```

Previously `[A, B][]` was rejected ("arrays of tuples are not supported
yet") — a deliberate guard plus an annotation-parser gap.

## Semantics

- The tuple-annotation parser accepts trailing `[]` suffixes; the checker's
  `typeFromAnnotation` recognizes `[A, B][]...` (leading `[` whose matching
  `]` is followed by `[]` suffixes), resolves the tuple, and wraps it in a
  `nested_array` per level (spec 289's variant; `arrayOfAlloc` now wraps
  tuple elements too).
- `for (const [a, b] of pairs)` over a two-element tuple array destructures
  each element into the two bindings (new `is_tuple_pairs` for-of form);
  plain `for (const p of pairs)` with `p[0]`/`p[1]` also works.

## Success Criteria

- **SC-001**: A `[i32, string][]` literal iterates plainly and by pair
  destructuring, and indexes at both levels.
- **SC-002**: Destructuring pairs into a Map works.
- **SC-003**: `zig build` and `zig build test` stay green.

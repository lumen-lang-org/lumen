# Spec 268: for...of over Sets

## Goal

```ts
const set: Set<i32> = new Set([1, 2, 2, 3])
for (const v of set) {
  console.log(v)      // 1, 2, 3 (insertion order)
}
```

Previously: "`for...of` needs an array, string, or Map".

## Semantics

`for (const v of set)` iterates the set's values in insertion order (the
runtime set is backed by an ordered list). The unsupported-iterable message
now lists Set.

## Success Criteria

- **SC-001**: Iteration visits each distinct element once, in order, after
  add/delete operations.
- **SC-002**: `zig build` and `zig build test` stay green.

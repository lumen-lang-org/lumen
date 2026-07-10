# Spec 133: negative indices in slice()

## Goal

Fix `slice()` on strings and arrays so a negative start or end index counts from
the end of the sequence, as JavaScript specifies:

```ts
"hello".slice(-3)      // "llo"   (was "hello")
"hello".slice(-3, -1)  // "ll"    (was "")
[1,2,3,4,5].slice(-2)  // [4,5]   (was [1,2,3,4,5])
```

Previously a negative endpoint was clamped to `0`, so `slice(-n)` returned the
whole sequence instead of the last `n` elements.

## Why a fix, not a feature

The endpoints were mis-clamped. `substring` is unchanged: per JS it treats a
negative endpoint as `0` (that behavior was already correct and stays).

## Semantics

For `slice`, each endpoint `i` normalizes as:

- `i < 0`  -> `max(len + i, 0)`
- `i >= 0` -> `min(i, len)`

The result runs from the normalized start up to (not including) the normalized
end, and is empty when start > end. `substring` keeps its own rule (negative ->
0, and it swaps endpoints so the smaller is the start).

## Requirements

- **FR-001**: `slice` on a string or array counts a negative start/end from the
  end before clamping into `[0, len]`.
- **FR-002**: A negative index whose magnitude exceeds `len` clamps to `0`
  (`"hello".slice(-10)` -> `"hello"`).
- **FR-003**: `substring` behavior is unchanged.

## Success Criteria

- **SC-001**: `"hello".slice(-3)` -> `llo`; `"hello".slice(-3, -1)` -> `ll`;
  `"hello".slice(-10)` -> `hello`; `"hello".slice(2)` -> `llo`.
- **SC-002**: `[1,2,3,4,5].slice(-2)` -> `4,5`;
  `[1,2,3,4,5].slice(-3, -1)` -> `3,4`; `[1,2,3,4,5].slice(-100)` ->
  `1,2,3,4,5`.
- **SC-003**: `"hello".substring(-2, 3)` -> `hel` (unchanged).
- **SC-004**: `zig build` and `zig build test` stay green.

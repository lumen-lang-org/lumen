# Spec 173: indexing an array literal

## Goal

Allow indexing an array literal directly, the lookup-table pattern:

```ts
["zero", "one", "two", "three"][x];   // "three" when x == 3
[10, 20, 30][i];
```

Previously indexing a bare array literal with a runtime value failed to build
(the literal lowered to a tuple, which cannot be indexed at runtime).

## Why additive, not breaking

Only makes previously-broken programs compile. Indexing an array variable or a
chained result is unchanged.

## Semantics

A bare array-literal index receiver is wrapped in a real `[]const T` slice (using
the element type the checker resolved), so a runtime index reads the element as
for any array. This mirrors the same fix for array-literal method receivers
(spec 130).

## Requirements

- **FR-001**: `[<items>][i]` reads element `i` for a runtime index `i`.
- **FR-002**: Indexing an array variable or expression result is unchanged.

## Success Criteria

- **SC-001**: `["zero","one","two","three"][3]` -> `three`;
  `[100,200,300][x - 1]` (x = 3) -> `300`.
- **SC-002**: `[10,20,30][i]` for `i` in `0..3` reads `10`, `20`, `30`.
- **SC-003**: `days[1]` (array variable) is unchanged.
- **SC-004**: `zig build` and `zig build test` stay green.

# Spec 093: array toSorted / toReversed

## Goal

JavaScript (ES2023) added `toSorted`/`toReversed` as the non-mutating
counterparts of `sort`/`reverse`. Lumen's arrays are already immutable, so
`sort`/`reverse` here never mutate — but providing the `to*` names lets code
written against the modern JS API compile unchanged and reads more clearly as
"returns a new array".

## Why additive, not breaking

`toSorted` and `toReversed` are aliases that share the exact type-checking and
lowering of `sort` and `reverse`. No behavior changes for existing programs.

## API

Instance methods on a `T[]` value:

- `toSorted(cmp: (a: T, b: T) => int): T[]` — a new, stably sorted array
  (identical to `sort`).
- `toReversed(): T[]` — a new array with the elements reversed (identical to
  `reverse`).

## Requirements

- **FR-001**: `toSorted` requires one comparator argument and `toReversed` none,
  with the same diagnostics as `sort`/`reverse` (`E_TYPE_MISMATCH`,
  `E_ARG_COUNT`).
- **FR-002**: Both return a new array; the receiver is unchanged.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `xs = [3,1,2]`: `xs.toSorted((a, b) => a - b)` -> `[1,2,3]`,
  `xs.toReversed()` -> `[2,1,3]`, and `xs` still reads `[3,1,2]`.
- **SC-002**: `zig build` and `zig build test` stay green.

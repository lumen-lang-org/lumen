# Spec 090: array findLast / findLastIndex

## Goal

`find`/`findIndex` scan from the front. Their from-the-end counterparts
`findLast`/`findLastIndex` are the natural way to get the last element (or its
index) satisfying a predicate, without reversing the array first.

## Why additive, not breaking

Pure additions to `arrayMethod`, reusing the same optional-index predicate
machinery (`cbParamsMatch` + `cb_wants_index`) as `find`/`findIndex`. They scan
the whole array keeping the last match.

## API

Instance methods on a `T[]` value, each taking a `(T) => bool` or
`(T, int) => bool` predicate:

- `findLast(fn): T | null` — the last element for which the predicate holds, or
  null.
- `findLastIndex(fn): int` — the index of that element, or `-1`.

## Requirements

- **FR-001**: The predicate must take one element-typed parameter, or two where
  the second is an integer index, and return `bool`; any other shape reports
  `E_TYPE_MISMATCH`. A wrong argument count reports `E_ARG_COUNT`.
- **FR-002**: Both scan the entire array and report the greatest-index match;
  with no match, `findLast` yields `null` and `findLastIndex` yields `-1`.
- **FR-003**: The optional index parameter, when declared, receives the
  zero-based position.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `xs = [10,25,30,45,20]`: `xs.findLast(v => v < 30)` -> `20`,
  `xs.findLastIndex(v => v < 30)` -> `4`, `xs.findLast(v => v > 100)` -> `null`,
  `xs.findLastIndex((v, i) => i < 3)` -> `2`.
- **SC-002**: `zig build` and `zig build test` stay green.

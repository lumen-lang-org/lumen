# Spec 064: array search methods (findIndex, lastIndexOf)

## Goal

Arrays already expose `find`, `indexOf`, and `includes`. Two common search
siblings were missing and forced callers to hand-roll index loops:
`findIndex` (predicate → position) and `lastIndexOf` (value → last position).
Both lower through the same inline-block machinery as their existing siblings.

## Why additive, not breaking

Pure additions to `arrayMethod`; nothing existing changes shape or behavior.
`findIndex` reuses `find`'s predicate lowering with `indexOf`'s `i32` result;
`lastIndexOf` reuses `indexOf`'s element-equality lowering without the early
`break`, so the last match wins.

## API

Instance methods on a `T[]` value:

- `findIndex(fn: (T) => bool): int` — index of the first element for which the
  predicate is true, or `-1`.
- `lastIndexOf(x: T): int` — index of the last element equal to `x`, or `-1`.

## Requirements

- **FR-001**: Each method is callable with TypeScript call shape and yields
  `int`.
- **FR-002**: `findIndex` requires a single `(T) => bool` callback; a mismatched
  callback shape reports `E_TYPE_MISMATCH`. `lastIndexOf` requires a single
  argument assignable to the element type `T`.
- **FR-003**: A wrong argument count reports `E_ARG_COUNT`.
- **FR-004**: `findIndex` scans left to right and returns at the first match;
  `lastIndexOf` returns the greatest matching index. Both return `-1` when there
  is no match.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: A program exercising both methods over `int[]` and `string[]`
  compiles and prints the expected indices (e.g. `[10,20,30,20,40]`:
  `findIndex(x => x > 25)` -> `2`, `lastIndexOf(20)` -> `3`).
- **SC-002**: No-match cases return `-1`.
- **SC-003**: `zig build` and `zig build test` stay green.

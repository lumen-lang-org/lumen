# Spec 106: array copyWithin

## Goal

`copyWithin` copies a block of the array to another position within it — a cheap
way to shift or duplicate a region. In Lumen's immutable model it returns a new
array rather than mutating the receiver.

## Why additive, not breaking

Pure addition to `arrayMethod`. It allocates a copy (like `fill`/`with`) and
overwrites a range from another range of the *original*, so overlap is handled
naturally (source reads come from the untouched input). The source array is
never mutated.

## API

Instance method on a `T[]` value:

- `copyWithin(target: int, start?: int, end?: int): T[]` — a copy of the array
  with the block `[start, end)` written starting at index `target`. `start`
  defaults to `0`, `end` to `length`. All three count from the end when
  negative and are clamped into `[0, length]`; the copy length is
  `min(end - start, length - target)`, so it never runs past the array.

## Requirements

- **FR-001**: Requires one to three integer arguments; a non-integer argument
  reports `E_TYPE_MISMATCH`, zero or more than three reports `E_ARG_COUNT`.
- **FR-002**: The result is a new array of the same length; the receiver is
  unchanged. Only the target range is overwritten, sourced from the original
  array's `[start, end)`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `xs = [1,2,3,4,5]`: `xs.copyWithin(0, 3)` -> `[4,5,3,4,5]`,
  `xs.copyWithin(1, 3)` -> `[1,4,5,4,5]`, `xs.copyWithin(0, 3, 4)` ->
  `[4,2,3,4,5]`, `xs.copyWithin(-2, 0)` -> `[1,2,3,1,2]`, and `xs` still reads
  `[1,2,3,4,5]`.
- **SC-002**: `zig build` and `zig build test` stay green.

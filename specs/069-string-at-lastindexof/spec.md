# Spec 069: string at and lastIndexOf

## Goal

Two more string search/access siblings of already-working methods: `at` (like
`charAt`, but with negative-from-end indexing) and `lastIndexOf` (like
`indexOf`, but the last match). Both lower through the uniform string
inline-block machinery.

## Why additive, not breaking

Pure additions to the `stringMethod` spec table and the string-method emit
chain. `at` reuses `charAt`'s single-character extraction with a negative-index
fixup; `lastIndexOf` reuses `indexOf`'s lowering with `std.mem.lastIndexOf`.

## API

Instance methods on a `string` value:

- `at(i: int): string` — the one-byte substring at `i`. Negative `i` counts
  from the end (`-1` is the last byte). Out-of-range yields `""`.
- `lastIndexOf(sub: string): int` — byte index of the last occurrence of `sub`,
  or `-1`.

Strings stay byte slices; indices are byte-oriented.

## Requirements

- **FR-001**: `at` takes one integer; `lastIndexOf` takes one string. Wrong
  types report `E_TYPE_MISMATCH`; wrong counts report `E_ARG_COUNT`.
- **FR-002**: `at` maps a negative index `i` to `length + i`; any index still
  outside `[0, length)` yields `""` (no trap), matching `charAt`'s
  out-of-range behavior.
- **FR-003**: `lastIndexOf` returns the greatest starting index of `sub`, or
  `-1` when absent.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `"hello".at(-1)` -> `o`, `"hello".at(0)` -> `h`, `"hello".at(5)`
  -> `""`; `"banana".lastIndexOf("a")` -> `5`, `"banana".lastIndexOf("na")` ->
  `4`, `"banana".lastIndexOf("z")` -> `-1`.
- **SC-002**: `zig build` and `zig build test` stay green.

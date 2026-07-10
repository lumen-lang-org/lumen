# Spec 070: array at

## Goal

Indexing with `a[i]` traps out of range and has no negative form. `at` is the
safe, ergonomic accessor: it returns an optional element, supports
negative-from-end indexing, and yields `null` (not a trap) when out of range —
the array counterpart of string `at` (spec 069) and a sibling of `find`'s
optional result.

## Why additive, not breaking

Pure addition to `arrayMethod`. The optional result is built exactly like
`find`'s (`T | null`), and consumers use the existing `??` / null-narrowing
machinery.

## API

Instance method on a `T[]` value:

- `at(i: int): T | null` — element at index `i`. Negative `i` counts from the
  end (`-1` is the last element). Out of range yields `null`.

## Requirements

- **FR-001**: `at` takes exactly one integer argument; a non-integer reports
  `E_TYPE_MISMATCH`, a wrong count reports `E_ARG_COUNT`.
- **FR-002**: A negative index `i` maps to `length + i`; any index still outside
  `[0, length)` yields `null` rather than trapping.
- **FR-003**: The result type is `T | null`, consumable via `??` and
  null-narrowing.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `xs = [10,20,30]`: `xs.at(0) ?? -1` -> `10`,
  `xs.at(-1) ?? -1` -> `30`, `xs.at(3) ?? -1` -> `-1`, `xs.at(-4) ?? -1` ->
  `-1`.
- **SC-002**: `zig build` and `zig build test` stay green.

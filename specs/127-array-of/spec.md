# Spec 127: Array.of

## Goal

`Array.of(...items)` builds an array from its arguments — the explicit
constructor form, useful when an array literal is awkward (single element,
generated call). Unlike a bare array literal used as a value, it produces a
proper heap-backed slice that can be returned and chained.

## Why additive, not breaking

Pure addition to the `Array` static namespace (alongside `Array.isEmpty`). It
allocates a fresh array and assigns each argument, so the result is a real
`[]const T` (no anonymous-tuple pitfalls).

## API

- `Array.of(...items: T): T[]` — a new array containing the arguments in order.
  At least one argument is required; all must share one type.

## Requirements

- **FR-001**: Requires one or more arguments, all of the same type; a type
  mismatch reports `E_TYPE_MISMATCH`, zero arguments reports `E_ARG_COUNT`.
- **FR-002**: The result is a heap-backed `T[]` usable with every array method
  (`.map`, `.join`, indexing) and safe to return.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Array.of(1, 2, 3).join(",")` -> `1,2,3`, `Array.of(42).length`
  -> `1`, `Array.of("a", "b", "c").join("-")` -> `a-b-c`,
  `Array.of(1, 2, 3).map(v => v * 2).join(",")` -> `2,4,6`.
- **SC-002**: `zig build` and `zig build test` stay green.

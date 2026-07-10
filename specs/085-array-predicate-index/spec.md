# Spec 085: element index for filter/find/some/every

## Goal

Spec 084 gave `map`/`forEach` an optional element index. The predicate methods
`filter`, `find`, `some`, and `every` should accept the same optional second
callback parameter, so predicates can depend on position (keep even indices,
find the element at a boundary, etc.).

## Why additive, not breaking

Reuses the `cb_wants_index` mechanism from spec 084. The predicate callback may
now be `(T) => bool` or `(T, int) => bool`; the single-parameter form is
unchanged. The emitter only captures and passes the loop index when the callback
declares it.

## API

Instance methods on a `T[]` value, each taking a `(T) => bool` or
`(T, int) => bool` predicate:

- `filter(fn): T[]` — elements for which the predicate holds.
- `find(fn): T | null` — first matching element, or null.
- `some(fn): bool` / `every(fn): bool` — existential / universal quantifier.

## Requirements

- **FR-001**: The predicate must take one element-typed parameter, or two where
  the second is an integer index, and must return `bool`; any other shape
  reports `E_TYPE_MISMATCH`. A wrong argument count reports `E_ARG_COUNT`.
- **FR-002**: When the predicate declares the index parameter it receives the
  zero-based position; the one-parameter form behaves exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `xs = [10,20,30,40,50]`:
  `xs.filter((v, i) => v > 0 && i % 2 == 0)` -> `[10,30,50]`,
  `xs.find((v, i) => v > 0 && i == 3)` -> `40`,
  `xs.every((v, i) => v == (i + 1) * 10)` -> `true`.
- **SC-002**: `zig build` and `zig build test` stay green.

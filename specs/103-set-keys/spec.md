# Spec 103: Set.keys

## Goal

In JavaScript a `Set` exposes both `values()` and `keys()`, which return the
same thing (the elements, in insertion order) — `keys` exists so `Set` and `Map`
share an iteration interface. Lumen had `values()` but not `keys()`.

## Why additive, not breaking

`keys()` is an alias of `values()`: it shares the checker branch and gets a
one-line alias method on the `Set` runtime struct. Nothing existing changes.

## API

- `Set<T>.keys(): T[]` — the elements in insertion order (identical to
  `values()`).

## Requirements

- **FR-001**: Takes no arguments and returns `T[]`; passing an argument reports
  a type/arg-count diagnostic.
- **FR-002**: The result equals `values()` — the elements in insertion order.

### Diagnostics
Reuses `E_ARG_COUNT` / `E_TYPE_MISMATCH`.

## Success Criteria

- **SC-001**: For a `Set<int>` built from `10, 20, 30`: `keys().join(",")` ->
  `10,20,30`, equal to `values().join(",")`, and `keys().length` -> `3`.
- **SC-002**: `zig build` and `zig build test` stay green.

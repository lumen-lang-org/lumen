# Spec 088: Map/Set clear

## Goal

`Map` and `Set` could grow (`set`/`add`) and shrink one entry at a time
(`delete`), but there was no way to empty them in one call. `clear` removes all
entries, matching JavaScript.

## Why additive, not breaking

Pure additions to the runtime container structs and the `mapMethod`/`setMethod`
checkers; the generic container-method emit already lowers `m.clear()` to the
runtime method, so no emit change is needed.

## API

- `Map<K, V>.clear(): void` — remove all key/value pairs.
- `Set<T>.clear(): void` — remove all elements.

After `clear`, `size` is `0` and the container is still usable (further
`set`/`add` work normally).

## Requirements

- **FR-001**: `clear` takes no arguments; passing one reports `E_ARG_COUNT`.
- **FR-002**: After `clear`, `size` is `0` and previously present keys/elements
  report `has` as `false`.
- **FR-003**: The container remains usable after `clear`.

### Diagnostics
Reuses `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: Building a `Map` with two entries, calling `clear`, then reading
  `size` -> `0` and `has` -> `false`; a subsequent `set` brings `size` back to
  `1`. Same for `Set` with `add`.
- **SC-002**: `zig build` and `zig build test` stay green.

# Spec 084: array map/forEach element index

## Goal

`map` and `forEach` passed only the element to their callback, so anything
index-dependent (building `"item N"` labels, comparing to position) needed an
external counter. This adds the optional second callback parameter — the
element's index — matching JavaScript.

## Why additive, not breaking

The callback may now be `(T) => U` or `(T, int) => U`; the single-parameter form
is unchanged. A new `cb_wants_index` flag on the method-call node records which
shape was used, and the emitter passes the loop index only when the callback
declares it (so no unused-capture is generated for the common one-parameter
case).

## API

Instance methods on a `T[]` value:

- `map(fn: (T) => U | (T, int) => U): U[]` — the callback receives each element
  and, if it declares a second parameter, its integer index.
- `forEach(fn: (T) => void | (T, int) => void): void` — same optional index.

## Requirements

- **FR-001**: The callback must take one parameter of the element type, or two
  where the second is an integer index; any other shape reports
  `E_TYPE_MISMATCH`. A wrong argument count to `map`/`forEach` itself reports
  `E_ARG_COUNT`.
- **FR-002**: When the callback declares the index parameter, it receives the
  zero-based position; the one-parameter form behaves exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: For `xs = [10,20,30]`: `xs.map((v, i) => v + i)` ->
  `[10,21,32]`; `xs.map(v => v * 2)` -> `[20,40,60]`; a two-parameter
  `forEach` observes indices `0,1,2`.
- **SC-002**: `zig build` and `zig build test` stay green.

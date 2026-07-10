# Spec 128: Array.from

## Goal

`Array.from(x)` converts an iterable to an array — most usefully a string into
its characters, or an existing array into a shallow copy.

## Why additive, not breaking

Pure addition to the `Array` static namespace (alongside `Array.isEmpty` /
`Array.of`). Nothing existing changes.

## API

- `Array.from(s: string): string[]` — an array of the string's single-character
  substrings, in order.
- `Array.from(a: T[]): T[]` — a shallow copy of the array (a new backing slice).

## Requirements

- **FR-001**: Takes exactly one argument, a string or an array; any other type
  reports `E_TYPE_MISMATCH`, a wrong count reports `E_ARG_COUNT`.
- **FR-002**: For a string, the result has one element per byte; for an array,
  the result is a new array with the same elements (usable with every array
  method).

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Array.from("hello").join(",")` -> `h,e,l,l,o`;
  `Array.from("hi").length` -> `2`; `Array.from([1,2,3]).join(",")` -> `1,2,3`;
  `Array.from([1,2,3]).map(v => v * 10).join(",")` -> `10,20,30`.
- **SC-002**: `zig build` and `zig build test` stay green.

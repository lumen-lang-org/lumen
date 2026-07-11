# Spec 183: zero-argument `string.slice()` / `substring()`

## Goal

Accept `slice()` / `substring()` with no arguments on a string, which JS treats
as a whole-string copy:

```ts
"hello".slice();       // "hello"
"world".substring();   // "world"
```

Previously the string forms required at least one argument (`E_ARG_COUNT`),
though the array `slice()` no-arg form already worked.

## Why additive, not breaking

Only makes previously-rejected programs compile. The one- and two-argument
forms, negative indices, and `substring`'s endpoint clamping are unchanged.

## Semantics

With no start argument, the start defaults to 0; with no end argument, the end
is the string length. So `s.slice()` and `s.substring()` both return the whole
string.

## Requirements

- **FR-001**: `s.slice()` / `s.substring()` return the whole string.
- **FR-002**: The one-/two-argument and negative-index forms are unchanged.

## Success Criteria

- **SC-001**: `"hello".slice()` -> `hello`; `"world".substring()` -> `world`.
- **SC-002**: `"hello".slice(2)` -> `llo`; `"hello".slice(1,3)` -> `el`;
  `"hello".slice(-2)` -> `lo`.
- **SC-003**: `zig build` and `zig build test` stay green.

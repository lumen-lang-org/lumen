# Spec 166: new Map(entries) initializer

## Goal

Allow a `Map` to be constructed from an array of `[key, value]` pairs, as in
JavaScript, with the element types inferable:

```ts
const m = new Map<string, i32>([["a", 1], ["b", 2], ["c", 3]]);
const inferred = new Map([["x", 10], ["y", 20]]);  // Map<string, i32>
```

Previously the `Map` constructor accepted no arguments; an entries array reported
`E_ARG_COUNT`, and the `<K, V>` type arguments were always required.

## Why additive, not breaking

Only makes previously-rejected programs compile. `new Map<K, V>()` (empty) is
unchanged.

## Semantics

`new Map(entries)` where `entries` is an array literal of two-element `[key,
value]` array literals creates a map and sets each pair in order. With explicit
`<K, V>` type arguments, every entry's key/value must match; with no type
arguments, `K`/`V` are inferred from the first entry and every later entry must
agree. Each entry must be a two-element array literal.

## Requirements

- **FR-001**: `new Map([[k, v], ...])` initializes the map with the pairs.
- **FR-002**: `<K, V>` may be omitted and inferred from the first entry.
- **FR-003**: Each entry must be a two-element array literal; otherwise
  `E_TYPE_MISMATCH`. Mismatched entry types report `E_TYPE_MISMATCH`.
- **FR-004**: `new Map<K, V>()` (empty) is unchanged.

## Success Criteria

- **SC-001**: `new Map<string,i32>([["a",1],["b",2],["c",3]]).size` -> `3`;
  `.get("b")` -> `2`.
- **SC-002**: `new Map([["x",10],["y",20]])` infers `Map<string, i32>`;
  `.get("x")` -> `10`, `.size` -> `2`.
- **SC-003**: `new Map<string,i32>().size` -> `0`.
- **SC-004**: `zig build` and `zig build test` stay green.

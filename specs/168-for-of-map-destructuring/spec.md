# Spec 168: for...of Map destructuring

## Goal

Support the idiomatic Map iteration `for (const [k, v] of map)`:

```ts
const m = new Map<string, i32>([["a", 1], ["b", 2], ["c", 3]]);
for (const [k, v] of m) console.log(k, v);   // a 1 / b 2 / c 3
```

Previously iterating a Map required `for (const k of m.keys())` plus a lookup, or
`m.forEach(...)`; the `[k, v]` for-of binding was a syntax error.

## Why additive, not breaking

Only makes previously-rejected programs compile. Single-binding `for...of` over
arrays and strings is unchanged.

## Semantics

`for (const [k, v] of map)` binds `k` to each key (type `K`) and `v` to the
corresponding value (type `V`), iterating the map's entries in insertion order.
The iterable must be a `Map`; a non-map pair-destructuring for-of reports
`E_TYPE_MISMATCH`.

## Requirements

- **FR-001**: `for (const [k, v] of map)` binds key and value per entry.
- **FR-002**: The iterable must be a `Map`.
- **FR-003**: Single-binding `for...of` (arrays, strings) is unchanged.

## Success Criteria

- **SC-001**: `for (const [k, v] of new Map([["a",1],["b",2],["c",3]]))
  console.log(k, v)` prints `a 1`, `b 2`, `c 3`.
- **SC-002**: Summing `v` across `for (const [k, v] of m)` yields the total of
  the values.
- **SC-003**: `zig build` and `zig build test` stay green.

# Spec 194: spreading a Set / string into a rest-parameter call

## Goal

Support spreading a Set or a string into a call's rest parameter:

```ts
function sum(...xs: i32[]): i32 { /* ... */ }
sum(...new Set([1, 2, 3]));   // 6
sum(1, ...new Set([2, 3]), 4); // 10

function first(...cs: string[]): string { return cs[0]; }
first(..."abc");               // "a"
```

Previously only an array could be spread into a rest parameter
(`E_TYPE_MISMATCH` otherwise). Companion to specs 192/193 (Set/string spread in
array literals).

## Why additive, not breaking

Only makes previously-rejected calls compile. Spreading an array into a rest
parameter, and all fixed-arity calls, are unchanged.

## Semantics

`f(...set)` / `f(...str)` feed the rest parameter the Set's values (insertion
order) / the string's single-character strings, exactly as an array spread
would. Implemented by rewriting the spread source to `Array.from(x)` during
argument checking. Composes with fixed arguments and other spreads.

## Requirements

- **FR-001**: A Set or string may be spread into a rest parameter.
- **FR-002**: Composes with fixed arguments and array spreads in the same call.
- **FR-003**: Array spreads into rest parameters are unchanged.

## Success Criteria

- **SC-001**: `sum(...new Set([1,2,3]))` -> `6`; `sum(...[10,20,30])` -> `60`.
- **SC-002**: `sum(1, ...new Set([2,3]), 4)` -> `10`.
- **SC-003**: `first(..."abc")` -> `a`.
- **SC-004**: `zig build` and `zig build test` stay green.

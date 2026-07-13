# 389 — Generic type annotation immediately before `=` initializer

## Problem

A generic-typed field or variable with an initializer and no space before `=`
was a syntax error:

```ts
class Cache { data: Map<string, i32> = new Map<string, i32>(); }  // syntax error at `=`
const m: Map<string, i32> = new Map<string, i32>();               // same
```

The lexer combines `>=` into a single comparison token, so the `>` closing the
type-argument list was swallowed together with the initializer's `=`.

## Change

`lumen_parser_expr.zig`, `consumeTypeArgClose`: when the token closing a
type-argument list is `>=` (a `Map<…>=` before an initializer), split it —
consume the `>` and leave an `=` op for the field/variable parser. The nested
`>>=` case (`Array<Array<X>>=`) is split into `>` plus a remaining `>=` for the
enclosing level, mirroring the existing `>>` handling.

## Verified

`zig build` + `zig build test` green. Probes:

- `class Cache { data: Map<string, i32> = new Map<…>(); … }` — compiles; the
  cache put/get round-trips (`5`).
- `class Uniq { seen: Set<i32> = new Set<i32>(); … }` — dedup works.
- `const m: Map<string, i32> = new Map<…>()` — variable form.
- `const a: Array<Array<i32>> = [[1],[2]]` — nested generic (`>>=`).
- `x >= 3` comparisons still parse as `>=`.

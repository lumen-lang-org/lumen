# Spec 435 — `new Map` from a non-literal entries expression

## Problem

`new Map<K, V>([["a", 1], ["b", 2]])` worked with an **inline** array literal,
but the same constructor rejected an entries **expression** of the identical
`[K, V][]` type:

```ts
const entries: [string, number][] = [["x", 10]];
const m = new Map<string, number>(entries); // error: type mismatch
```

The checker required `ne.args[0]` to be a literal `.array` node, and the emitter
only iterated literal entries — a non-literal argument would have silently
produced an empty map.

## Change

The `Map` constructor now accepts any `[K, V][]`-typed argument:

- **Checker** (`lumen_check_expr.zig`): the inline-literal path is unchanged
  (per-entry inference and integer-literal widening). A non-literal argument
  requires explicit `<K, V>` type arguments (it can't seed K/V inference) and is
  validated by assignability against `[K, V][]` (built as
  `nested_array(tuple_type{K, V})`).
- **Emitter** (`lumen_emit.zig`): a non-literal entries expression lowers to a
  runtime loop — `for (__src) |__e| { __c.set(__e.@"0", __e.@"1"); }` — reading
  each tuple pair's fields, mirroring the existing `new Set(expr)` path.

## Verification

- `zig build` and `zig build test` clean.
- `new Map<string, number>(entries)` from a variable → correct lookups and size.
- `new Map<string, number>(names.map((n, i): [string, number] => [n, i]))` from a
  `.map(...)` result → populated map.
- Numeric keys (`new Map<number, string>(pairs)`) work.
- Inline-literal construction is unchanged.
- A non-literal argument with no type arguments reports a clean
  `E_TYPE_ARG_COUNT` instead of miscompiling.

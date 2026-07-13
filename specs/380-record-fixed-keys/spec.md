# 380 — `Record<K, V>` with a fixed key set

Third type-level step, composing with `keyof` (spec 379) and utilities (378).

## Problem

`Record<K, V>` was always rejected in favor of `Map`. But a `Record` over a
*fixed* key set is a static record shape, not dynamic storage:

```ts
type Scores = Record<"math" | "art", i32>;   // { math: i32, art: i32 }
type Flags  = Record<keyof P, bool>;         // one bool per field of P
```

## Change

`lumen_check.zig`, the `Record` case of `typeFromAnnotation`:

- `recordKeyLiterals(K)` extracts a fixed key set from `K` — a raw `"a" | "b"`
  literal union, a `keyof P` operand, or a named string-literal-union type — or
  returns null when `K` is a dynamic `string`.
- With a fixed key set, `synthRecordFromKeys` builds a record with one field per
  key, each typed `V`, registers it, and queues it for emission (same mechanism
  as the utility types).
- A dynamic `Record<string, V>` still points to `Map<string, V>`, now with a
  clearer message that also names the fixed-key forms.

## Verified

`zig build` + `zig build test` green. Probes:

- `Record<"math" | "art", i32>` — a two-field record; `s.math` / `s.art` work.
- `Record<keyof P, bool>` — one `bool` field per field of `P`.
- `Record<"only", string>` — single key.
- `Record<string, i32>` — rejected, pointing at `Map` or a fixed key set.
- `Map<string, i32>` unchanged.

## Boundary

The value type `V` is uniform across all keys (true for `Record`). Dynamic
string/number keys remain `Map` — a `Record` needs a statically known key set.

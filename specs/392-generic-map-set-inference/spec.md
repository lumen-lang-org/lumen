# 392 — Type-parameter inference through `Map<K,V>` / `Set<T>` parameters

## Problem

A generic function taking a `Map` or `Set` could not infer its type parameters
from that argument, so a following callback parameter had nothing to bind to:

```ts
function mapVals<K, V, W>(m: Map<K, V>, f: (v: V) => W): W[] { … }
mapVals(m, x => x * 2)   // error: cannot infer type here (x)
```

## Change

`lumen_check_generics.zig`, `unifyAnnotation`: two container-pattern cases,
alongside the existing `T` / `T[]` / function-type patterns.

- `Map<K, V>` against a `map_type` argument unifies `K` against the key type and
  `V` against the value type (splitting the two args at the top-level comma).
- `Set<T>` against a `set_type` argument unifies `T` against the element type.

With `V` inferred from the map argument (processed before the callback), the
callback-parameter hinting from spec 354 then types the untyped arrow's
parameter, so `x => x * 2` reads `x: i32`.

## Verified

`zig build` + `zig build test` green. Probes:

- `mapVals(m, x => x * 2)` over `Map<string, i32>` → `10,14`.
- `keys(m)` inferring `K` from `Map<K, V>` → works.
- `toArr(s)` inferring `T` from `Set<T>` → `1,2`.
- Array callback inference (spec 354) unchanged.

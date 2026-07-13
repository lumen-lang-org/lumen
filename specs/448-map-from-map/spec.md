# Spec 448 — `new Map` from another Map

## Problem

`new Map(otherMap)` — cloning a map, the natural start of a merge — was rejected;
the `Map` constructor only accepted an entries array. (Companion to spec 446,
`new Set` from another Set.)

```ts
const a = new Map<string, number>([["x", 1], ["y", 2]]);
const b = new Map(a);   // error
```

Materializing `a.entries()` into a `[K,V][]` isn't supported (entries only
iterate in a `for…of`), so the Set-from-Set `Array.from` trick doesn't apply.

## Change

- **AST**: `new_expr` gains a `copy_container` flag.
- **Checker** (`lumen_check_expr.zig`): a single non-array-literal `Map`
  constructor argument that types as a `Map` sets `copy_container`. Its `K`/`V`
  are inferred from the source (or must match explicit type arguments).
- **Emitter** (`lumen_emit.zig`): a `copy_container` map initializes an empty map
  and copies each pair from the source's parallel `keys()`/`values()` slices —
  no intermediate entries array — mirroring the `for…of`-over-a-map lowering.

## Verification

- `zig build` and `zig build test` clean.
- `new Map<string, number>(a)` and inferred `new Map(a)` clone the map; lookups
  and `size` are correct.
- The copy is independent: mutating the clone leaves the source unchanged.
- Merge pattern (`const m = new Map(a); for (const [k,v] of b) m.set(k,v)`)
  works, later entries overriding earlier ones.

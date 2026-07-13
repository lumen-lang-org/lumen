# 409 — `Object.entries(record)`

## Problem

`Object.keys` and `Object.values` (spec 393) were supported, but the companion
`Object.entries` — the idiomatic way to iterate a record's key/value pairs — was
not:

```ts
type O = { a: number; b: number };
const o: O = { a: 1, b: 2 };
for (const [k, v] of Object.entries(o)) { … } // rejected
```

## Approach

Lumen has first-class tuple types and tuple arrays, so `Object.entries` over a
homogeneous record produces `[string, V][]`.

- **Check** (`lumen_check_expr.zig`): share the homogeneous-field-type resolution
  with `Object.values`; for `entries`, build a `[string, V]` tuple element type,
  wrap it in an array with `arrayOfAlloc`, and mark the call `object_entries`.
  Mixed field types are rejected with the same shared-type diagnostic.
- **AST** (`lumen_ast.zig`): add an `object_entries` flag.
- **Emit** (`lumen_emit_static.zig`): bind the receiver once, then build an array
  of positional tuple structs `.{ .@"0" = "key", .@"1" = rec.key }`, cast to the
  tuple-array type.

## Verification

- `for (const [k, v] of Object.entries({a:1,b:2}))` iterates `a=1`, `b=2`.
- String values: `Object.entries({x:"hi",y:"bye"})` → `x:hi`, `y:bye`.
- Indexing: `Object.entries(o)[0][0]` / `[0][1]` → key / value.
- `Object.entries(o).length` → field count.
- Mixed field types rejected with the shared-type diagnostic.
- `Object.keys` / `Object.values` unchanged.
- Full `zig build` + test suite green.

## Notes

Homogeneous records only (like `Object.values`): a heterogeneous record has no
single tuple element type. Completes the `keys`/`values`/`entries` trio.

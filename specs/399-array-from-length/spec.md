# 399 — `Array.from({ length: N }, (_, i) => …)` range generation

## Problem

The array-like generator form of `Array.from` — the idiomatic way to build a
range/sequence — was unsupported:

```ts
const a = Array.from({ length: 3 }, (_, i) => i * 2); // cannot infer variable type
```

The object literal `{ length: 3 }` has no named record type, so `exprType`
failed on it and the whole call went untyped.

## Approach

Special-case an `Array.from` whose first argument is an object literal with a
single `length` field and a mapping callback.

- **Check** (`lumen_check_stdlib.zig`): when `args[0]` is `{ length: <int> }` and
  a callback is present, resolve the length expression (must be integer), check
  the callback against `(i32, i32) => U` (value placeholder + index), record the
  length expression on the call node (`from_length`), and return `U[]`.
- **AST** (`lumen_ast.zig`): add `from_length: ?*Expr` to the static-call node.
- **Emit** (`lumen_emit_static.zig`): allocate `N` slots and fill each by calling
  the closure with a placeholder value `0` and the index `i`
  (`__cb.call(__cb.ctx, 0, i)`), mirroring `Array.from(src, cb)`'s mapping loop.

The value argument is `undefined` in JavaScript; here it is an unused `i32`
placeholder (always `0`), so the idiomatic `(_, i) => …` works and any code that
reads only the index behaves identically to Node.

## Verification

- `Array.from({length:3}, (_, i) => i*2)` → `[0,2,4]`.
- String result: `Array.from({length:3}, (_, i) => "x"+i)` → `x0,x1,x2`.
- Runtime length: `Array.from({length:n}, (_, i) => i)` → `0,1,2,3,4`.
- Existing `Array.from(arr)`, `Array.from(arr, cb)`, `Array.from(str)`,
  `Array.from(set)` unchanged.
- Full `zig build` + test suite green.

## Notes

A zero-parameter callback (`() => 9`) remains unsupported — the same
pre-existing `checkCbArg` limitation that rejects `arr.map(() => 9)`, not
specific to this form. Use `(_, i) => …` or `(v) => …`.

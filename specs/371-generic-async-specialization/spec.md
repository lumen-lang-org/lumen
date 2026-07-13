# 371 — Generic async functions specialize correctly

## Problem

A generic async function failed to type-check at its `return`:

```ts
async function id<T>(x: T): Promise<T> { return x; }
// error: type mismatch: expected `Promise<i32>`, got `i32`
```

Non-generic async and sync generics both worked. In an async body, `return v`
resolves the promise, so the value is checked against the promise's *inner*
type — but the specialized copy of the generic function had `is_async = false`,
so that unwrapping never happened and `return x` was checked against the full
`Promise<i32>`.

## Change

`lumen_check_generics.zig`, `specializeFunction`: the synthesized concrete
`FunctionDecl` now copies the modifiers that drive body checking and codegen
from the template — `is_async`, `infer_return`, `visibility`, `is_static`, and
`accessor` — instead of leaving them at their defaults. `is_async` is the one
that fixed this bug; the others are preserved for correctness (a generic
`static`/accessor/inference-typed function specialized the same way).

## Verified

`zig build` + `zig build test` green. Probes:

- `await id(42)` (inferred T) → `42`.
- `await id<i32>(7)` (explicit T) → `7`.
- `await id("hi")` (string T) → `hi`.
- Sync generic `id(42)`, `id("x")` still work.

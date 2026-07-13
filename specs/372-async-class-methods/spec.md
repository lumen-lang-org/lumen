# 372 — Async class methods

## Problem

`async` was not accepted as a class-method modifier. The parser's member-modifier
loop knew `public`/`private`/`protected`/`static`/`readonly`/`get`/`set` but not
`async`, so `async get(): Promise<i32>` was misparsed as a field named `async`:

```ts
class S { async get(): Promise<i32> { return 42; } }
// error: a class field needs a type annotation or an initializer
```

## Change

1. **Parser** (`lumen_parser_decl.zig`): `async` is recognized in the member
   modifier loop and sets `is_async` on the method — but only when followed by an
   identifier (so a member literally named `async` still parses as its own
   method/field, same lookahead trick as `get`/`set`).
2. **Emitter** (`lumen_emit_class.zig`, `emitClassMethod`): an async method sets
   `g_async_inner` to the promise's inner type (so `return v` resolves the
   promise with `v`), and an async `Promise<void>` method that falls through gets
   a trailing `return __promiseResolved(void, {})` — the same handling async free
   functions already had.

Checking already worked once `is_async` was set (methods route through
`checkFunctionBody`, which unwraps the promise inner type). Throwing async
methods compose with spec 368 (async throws are catchable).

## Verified

`zig build` + `zig build test` green. Probes:

- `async get(): Promise<i32> { return 42 }` → `await s.get()` = `42`.
- Async method reading a field (`this.base + n`) → `15`.
- Async `Promise<void>` method that only logs → runs, prints `hi`.
- Async method that throws, caught by the caller's `try/catch` → `caught`.
- A method literally named `async` (`async(): i32`) still works.
- Regular (non-async) methods unchanged.

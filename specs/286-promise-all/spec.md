# Spec 286: Promise.all

## Goal

```ts
async function main(): Promise<void> {
  const results: i32[] = await Promise.all([work(1), work(2), work(3)])
  console.log(results.join(","))   // 2,4,6
}
```

Previously E_UNSUPPORTED_STD (only `Promise.resolve` existed).

## Semantics

`Promise.all([p1, p2, ...])` returns `Promise<T[]>`. Lumen promises are
eager — they schedule on the shared event loop at creation — so awaiting
each element in turn still drives them all to completion concurrently (the
`Worker.run` probe runs three OS threads in parallel and collects their
results). Restricted to an **array literal** argument so the element
promise types are known positionally; all elements must be `Promise<T>` for
the same `T`, and `T` must have an array form (scalars, strings, named
records). The result is a resolved `Promise<T[]>`, so the usual
`await Promise.all(...)` yields `T[]`.

Errors: a non-array arg, an empty array, a non-promise element, mixed
resolve types, or a `T` with no array form each report a tailored message.

## Success Criteria

- **SC-001**: `await Promise.all([...])` over async functions returns the
  values in order, for `i32[]` and `string[]`.
- **SC-002**: `Promise.all` over `Worker.run(...)` runs the workers in
  parallel and collects their results.
- **SC-003**: Non-promise elements and mixed types report their messages.
- **SC-004**: `zig build` and `zig build test` stay green.

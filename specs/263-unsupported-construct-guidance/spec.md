# Spec 263: unsupported constructs point at the supported alternative

## Goal

Three common TS constructs that aren't in V1 now say so — and say what to
write instead — rather than a bare "syntax error" / code:

```text
error: inline object types are not supported — declare a named type
(`type T = { ... }`) and use its name          # { a: i32 } | null (spec 262)

error: arrays of tuples are not supported yet — use an array of a named
record type instead                             # [string, i32][]

error: constructing a Promise with an executor is not supported yet — use
an `async function` (with `await`/`setTimeout`) or `Promise.resolve(v)`

error: Promise.all is not supported yet — only Promise.resolve(v); use
`async`/`await` for composition
```

## Semantics

Parser/checker-level guidance only; no behavior change for supported code.

## Success Criteria

- **SC-001**: Each probe reports its tailored message at the right position.
- **SC-002**: Supported async/await, tuples, and named types unchanged;
  `zig build` and `zig build test` stay green.

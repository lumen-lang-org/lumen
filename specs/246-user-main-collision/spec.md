# Spec 246: user functions named `main` (and other generated globals)

## Goal

The idiomatic entry-point pattern compiles and runs:

```ts
async function main(): Promise<void> {
  const r: i32 = await work(5)
  console.log(r)
}
await main()
```

Previously any user function named `main` collided with the generated
program's own `main` and died with a backend error ("duplicate struct member
name 'main'"). Same for `std`, `xev`, and `builtin` — names the generated
code reserves at file scope.

## Semantics

A user function whose name collides with a generated-code global emits under
a `__lumen_user_` prefix; call sites, function-value thunks, and the
exception-propagation throwing set follow. Stack-trace frames and
diagnostics keep the source name — a trace says `at main (file.ts:6:9)`.

## Success Criteria

- **SC-001**: Sync and async `function main()` programs compile, run, and
  trace under the name `main`.
- **SC-002**: A throw inside user `main` reports `at main (...)` above
  `<main>`.
- **SC-003**: `zig build` and `zig build test` stay green.

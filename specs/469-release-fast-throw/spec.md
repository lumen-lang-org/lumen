# Feature Specification: A Release Build of a Throwing Program

## Problem

`--release-fast` could not compile any program containing `throw`.

```ts
function risky(n: int): int {
  if (n < 0) { throw new Error("negative"); }
  return n * 2;
}
function main(): void {
  try { console.log(`${risky(-1)}`); } catch (e) { console.log("caught: " + e.message); }
}
main();
```

```
$ lumen compile rf.ts                 # fine
$ lumen compile --release-fast rf.ts
rf.ts:1:1: error: use of undeclared identifier '__lumen_throwing'
```

`__lumen_throwing` and `__lumen_err_msg` were declared inside the block gated
on `runtime_locations`, which `--release-fast` turns off. The emitter writes
`__lumen_throwing = true` on every throw regardless, so nothing declared what
every throw assigned to.

These two are not decoration. `__lumen_line` and `__lumen_col` exist to make a
message readable and belong under that gate; the throw flag and the message are
what `throw` is *made of*. Declaring them together was the mistake.

## The larger question this exposes, deliberately left open

The compiler already says, beside the fixpoint pass that decides which
functions return error unions:

> Skipped for release-fast builds (no runtime location tracking): throws stay
> panics.

So a release build is *meant* to turn a throw into a panic. With the build
fixed, that becomes reachable and visible:

```
$ lumen run rf.ts                      # debug
caught: negative

$ ./rf                                 # --release-fast
thread panic: negative
```

The same program catches in one build and aborts in the other. That is a
serious footgun — a service that handles a bad request cleanly in development
dies on it in production — and it is not something to change quietly, because
error unions in release-fast cost what they cost. This spec fixes the build and
names the divergence; deciding what release-fast should do about exceptions is
its own decision.

## Scope

In scope:

- A program containing `throw` compiles under `--release-fast`.
- Behaviour under `--release-fast` is what the compiler already intended:
  throws panic, and the panic message is the thrown value.
- No change to debug builds.

Out of scope:

- Whether release-fast *should* panic. That is the open question above and
  wants a decision, not a patch.

## Design

Declare `__lumen_throwing` and `__lumen_err_msg` unconditionally, beside the
other runtime state, rather than inside the `runtime_locations` block. They are
per-call-stack, so they are `threadlocal` for the reason spec 468 gives.

## Success Criteria

1. The reproduction compiles under `--release-fast`.
2. It panics with `negative`, which is what the compiler intends today.
3. The debug build still prints `caught: negative`.
4. `zig build test` passes; `zig build conformance` adds no new failures.

## Notes

Found by an audit while fixing spec 468, and confirmed against `main` — this
predates that change. It means no program using exceptions has ever been
shippable as a release build, which is worth knowing about a language whose
standard library throws.

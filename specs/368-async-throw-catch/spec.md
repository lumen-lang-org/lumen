# 368 — Throwing inside async functions is catchable

## Problem

A `throw` inside an async function was silently miscompiled to an uncatchable
`@panic`: even with a surrounding `try/catch`, it crashed the program.

```ts
async function f(): Promise<i32> { throw new Error("x"); }
async function main(): Promise<void> {
  try { await f(); } catch (e) { console.log("caught"); }  // never ran
}
```

Output was `Uncaught Error: x` (a panic), not `caught`.

Root cause: the throwing-function fixpoint analysis
(`lumen_compiler.zig`) explicitly skipped async functions and methods
(`if (f.is_async) continue;` / `if (m.is_async) continue;`). So an async
function that threw was never marked throwing, which meant (a) its body emitted
`throw` as `@panic` instead of the error-return mechanism, and (b) call sites
(`await f()`) got no throw-check to route into the enclosing `catch`.

## Change

Removed both `is_async` exclusions from the throwing-set fixpoint. Async
functions now participate in the same exception machinery as sync functions:

- A throwing async function emits `error{LumenThrow}!*LumenPromise(T)` and its
  `throw` uses the catchable error-return path, not `@panic`.
- Lumen's async model is eager (`f()` runs the body synchronously and returns a
  resolved promise), so a throwing `f()` is wrapped by the existing
  throwing-call machinery; `await f()` = `(try f() …).await_()` naturally
  propagates the error to the enclosing `try/catch`, which routes to its
  `catch` slot exactly as a sync throwing call does.

Non-throwing async functions are unaffected (the fixpoint only marks a function
throwing when its body can actually throw).

## Verified

`zig build` + `zig build test` green. Probes:

- `try { await f() } catch` catches a direct async throw (prints `caught`).
- `(e as Error).message` inside the catch reads `boom`.
- Non-throwing async (`return 5`) still awaits to its value.
- An uncaught async throw prints a proper `Uncaught Error` with a stack trace
  (not a panic).
- Transitive throw through nested `await` chains is caught.
- An async function that conditionally throws returns normally on the other
  path (`await f(5)` → 10, `await f(-1)` → caught).
- `Promise.all([...])` over async functions still resolves.

## Boundary

Requires runtime locations (the exception mode, default for `run`/debug
builds); `--release-fast` keeps the existing panic-on-uncaught behavior for all
throws, sync and async alike.

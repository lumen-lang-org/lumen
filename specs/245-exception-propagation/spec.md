# Spec 245: exceptions propagate across function calls

## Goal

`try`/`catch` catches throws from called functions — at any depth — matching
JS semantics:

```ts
function risky(n: i32): i32 {
  if (n < 0) throw new Error("neg")
  return n
}
try {
  console.log(risky(-1))
} catch (e) {
  console.log("caught:", e.message)   // ← now runs
}
```

Previously only a `throw` written lexically inside the `try` block was
catchable; a throw inside a called function panicked the program with the
catch never running — a fundamental semantics gap surfaced while probing
runtime traces.

## Semantics

- A fixpoint pass before emission computes the set of functions that can
  leak a throw (a `throw` not swallowed by an enclosing `try`/`catch`, or a
  call to another throwing function — transitively). These emit as Zig error
  unions (`error{LumenThrow}!T`); `throw` stashes the message in a runtime
  global and returns the error.
- Call sites unwrap by context: inside a `try` body the error routes to that
  try's catch slot (same machinery lexical throws use); inside another
  throwing function it forwards (`try`); anywhere else it panics with the
  thrown message, so an uncaught error keeps the exact `file:line:col`,
  excerpt, and stack-trace rendering — with the full frame chain from the
  throw site (frame pops are suspended while an exception unwinds; a catch
  restores the depth it snapshotted at try entry).
- `finally` blocks run during propagation (they lower to defers). Rethrowing
  from a catch re-propagates. Catching resets the unwind state, so later
  traces are clean.
- Out of scope (unchanged panic behavior): async functions, class methods as
  throw *sources* (methods may call throwing functions; an uncaught result
  panics with the correct trace), arrow functions, and release-fast builds
  (no runtime location tracking).

## Success Criteria

- **SC-001**: A throw two calls deep is caught; the loop probe catches per
  iteration and continues.
- **SC-002**: An uncaught deep throw prints the full chain
  (`level3 → level2 → level1 → <main>`) with the throw site's position.
- **SC-003**: try/finally without catch runs cleanup then re-propagates to
  the caller's catch; catch-and-rethrow wraps the message.
- **SC-004**: Repeated caught exceptions leave no stale stack frames in a
  later uncaught trace.
- **SC-005**: Tests calling helpers that catch internally pass;
  `zig build` and `zig build test` stay green.

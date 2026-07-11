# Spec 205: `try { ... } finally { ... }` without a catch

## Goal

Support a try/finally with no catch clause:

```ts
function f(): i32 {
  let x = 0;
  try {
    x = 1;
  } finally {
    console.log("cleanup");
  }
  return x;
}
```

Previously a `try` required a `catch`; `try { } finally { }` was a syntax error.

## Why additive, not breaking

Only makes previously-rejected programs compile. `try/catch` and
`try/catch/finally` are unchanged.

## Semantics

`try { A } finally { B }` runs `A`, then always runs `B` (on normal completion,
an early return, or an in-flight throw). With no catch clause, a throw in `A` is
not handled: `B` runs and the throw re-propagates to the nearest enclosing
try/catch (a nested `try/finally` inside an outer `try/catch` runs the finally
then the outer catch handles it). A no-catch try/finally satisfies the
return-path check when its try body returns.

Because Lumen lowers `throw` per-function, a throw that would propagate across a
function-call boundary is still not caught by the caller's try (the pre-existing
cross-function limitation); an uncaught throw at the top level aborts.

## Implementation

- Parser: the `catch` clause is optional when a `finally` follows; `has_catch`
  records whether one was written.
- Emit: with no catch, an uncaught throw re-propagates after finally — breaking
  to the enclosing try's slot, or `@panic` at the top level. The throw slot is
  only emitted when needed, and throw-can-propagate / return-path analysis treat
  a no-catch try body as a throw/return source.

## Requirements

- **FR-001**: `try { } finally { }` (no catch) parses and runs both bodies.
- **FR-002**: A throw inside the try runs finally, then re-propagates to an
  enclosing try/catch.
- **FR-003**: `try/catch` and `try/catch/finally` are unchanged.

## Success Criteria

- **SC-001**: `try { x = 1; } finally { log("cleanup"); }` runs the assignment
  then the cleanup.
- **SC-002**: `try { try { throw ... } finally { log("inner") } } catch (e) {
  log("outer: " + e.message) }` prints `inner` then `outer: ...`.
- **SC-003**: `try/catch` still works.
- **SC-004**: `zig build` and `zig build test` stay green.

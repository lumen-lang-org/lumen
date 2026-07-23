# Tasks: Module-Level Bindings In `test` Blocks

## Investigation

- [x] Find where `lumen test` builds its entry point and how it differs from the
      `lumen run` entry point.
- [x] Determine whether top-level statements are emitted at all in test mode, or
      emitted into a scope the test bodies cannot see.
- [x] Confirm whether the checker registers module-level declarations in the
      scope stack that test bodies are checked against
      (`Checker.declare` / `freshEmitName`, `src/lumen_check.zig:722-732`).

## Implementation

- [x] Emit module-level bindings so they are visible to test block bodies.
- [x] Run top-level initializers exactly once, before the first test block.
- [x] Preserve declaration order.
- [x] Keep `lumen run` behaviour unchanged.

## Diagnostics

- [x] Never print the internal `__lumen_<id>_<name>` form in a user-facing error;
      report the source identifier instead.
- [x] Reject at compile time (under `lumen test`) a promoted binding whose
      initializer reads a `main`-local module binding (destructuring, group,
      `using`, accumulator) — a located error naming the binding, instead of a
      silently-uninitialized global. `lumen run`/`lumen compile` still work.

## Tests

- [x] Direct reference to a module-level `let` from a test block.
- [x] Direct reference to a module-level `const` from a test block.
- [x] Indirect reference through a function (the silent-garbage case).
- [x] Module-level `int` reads back its initialized value, not garbage.
- [x] Module-level record and array are readable from a test block.
- [x] Two test blocks read the same initialized value.
- [x] Initializer runs once, not once per test block.
- [x] A promoted binding derived from a module-level destructuring/group binding
      is rejected under `lumen test` but still runs under `lumen run`.

## Gates

- [x] `zig build test` passes.
- [x] One clean `zig build conformance` run, no regressions.
- [x] Add the reproduction programs as conformance examples.

# Tasks: Module-Level Bindings In `test` Blocks

## Investigation

- [ ] Find where `lumen test` builds its entry point and how it differs from the
      `lumen run` entry point.
- [ ] Determine whether top-level statements are emitted at all in test mode, or
      emitted into a scope the test bodies cannot see.
- [ ] Confirm whether the checker registers module-level declarations in the
      scope stack that test bodies are checked against
      (`Checker.declare` / `freshEmitName`, `src/lumen_check.zig:722-732`).

## Implementation

- [ ] Emit module-level bindings so they are visible to test block bodies.
- [ ] Run top-level initializers exactly once, before the first test block.
- [ ] Preserve declaration order.
- [ ] Keep `lumen run` behaviour unchanged.

## Diagnostics

- [ ] Never print the internal `__lumen_<id>_<name>` form in a user-facing error;
      report the source identifier instead.

## Tests

- [ ] Direct reference to a module-level `let` from a test block.
- [ ] Direct reference to a module-level `const` from a test block.
- [ ] Indirect reference through a function (the silent-garbage case).
- [ ] Module-level `int` reads back its initialized value, not garbage.
- [ ] Module-level record and array are readable from a test block.
- [ ] Two test blocks read the same initialized value.
- [ ] Initializer runs once, not once per test block.

## Gates

- [ ] `zig build test` passes.
- [ ] One clean `zig build conformance` run, no regressions.
- [ ] Add the reproduction programs as conformance examples.

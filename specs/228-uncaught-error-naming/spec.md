# Spec 228: "Uncaught Error" labeling + capture-use analysis fix

## Goal

Label an uncaught `throw` the way JS developers expect, distinct from safety
traps:

```text
g.ts:2:3: Uncaught Error: kaboom      # throw that nothing caught
g.ts:3:1: runtime error: index out of bounds: index 5, len 1   # safety trap
```

Previously both printed `runtime error:`.

## Semantics

An uncaught `throw` (top level, or a no-catch `try/finally` rethrow reaching
the top) sets a flag before panicking; the panic handler prints
`Uncaught Error:` for it and keeps `runtime error:` for safety traps (bounds,
overflow, division by zero, assertion failures). Caught throws are untouched.

## Bug fix (found while verifying)

`catch (e) { console.log("...", e.message) }` failed to build: the
name-use analysis for `console.log` only inspected the first argument, so a
capture (or parameter) referenced only from the second-plus argument was
"unused", emitted a discard, and Zig rejected the discard+use. The analysis
now covers `extra_values`. Same fix benefits function parameters used only in
a multi-argument `console.log`.

## Success Criteria

- **SC-001**: An uncaught throw prints `Uncaught Error: <msg>` with the usual
  excerpt and stack trace.
- **SC-002**: Bounds/overflow traps still print `runtime error:`.
- **SC-003**: `catch (e) { console.log("ok:", e.message) }` compiles and
  prints; a parameter used only in a multi-arg `console.log` compiles.
- **SC-004**: `zig build` and `zig build test` stay green.

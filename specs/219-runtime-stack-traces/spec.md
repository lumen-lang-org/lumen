# Spec 219: runtime stack traces

## Goal

Report a call-stack trace on every runtime error, in familiar JS style:

```text
g.ts:3:5: runtime error: division by zero
  3 |     return a / b
    |     ^
    at Calc.div (g.ts:3:5)
    at run (g.ts:8:3)
    at <main> (g.ts:10:1)
```

Previously a runtime error showed only the failing statement (file:line:col +
caret) with no indication of how execution got there.

## Semantics

Every runtime error that reaches the panic handler — uncaught `throw`, index
out of bounds, integer overflow, division by zero, assertion failure — prints,
after the existing source excerpt:

- one `at <name> (file:line:col)` frame per active user function, innermost
  first; class methods display as `Class.method`;
- each frame's location is where execution currently is inside it (the failing
  statement for the innermost frame, the call site for outer frames);
- a final `at <main> (...)` frame for top-level code;
- recursion deeper than the 128-frame capture window prints
  `... N deeper frames omitted` and the outermost recorded frames.

## Implementation

- Generated prelude: a fixed 128-slot frame stack (`name`, call-site line/col)
  with `__lumenPush`/`__lumenPop`; depth keeps counting past capacity so the
  omitted count is exact.
- Every user function and class method body begins with
  `__lumenPush("name"); defer __lumenPop();` — the entry push naturally
  captures the caller's current statement position (the call site), and
  `defer` pops on every exit path, including throws lowered to breaks.
- The panic handler walks the stack innermost-first, threading the display
  location from the current statement down through the recorded call sites.
- Gated on `runtime_locations` (the same flag as line tracking):
  `--release-fast` builds omit frames entirely, as before.

## Cost

One array store + two integer bumps per call in safe mode; nothing in
`--release-fast`.

## Success Criteria

- **SC-001**: An uncaught throw two calls deep prints
  `at inner`, `at outer`, `at <main>` with the correct positions.
- **SC-002**: Index-out-of-bounds and division-by-zero inside functions show
  the same trace shape; a method frame reads `Class.method`.
- **SC-003**: 200-deep recursion prints an omitted-frames count instead of
  overflowing.
- **SC-004**: `zig build` and `zig build test` stay green.

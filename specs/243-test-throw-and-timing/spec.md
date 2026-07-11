# Spec 243: thrown-error test failures + compile timing

## Goal

A test that dies on an uncaught throw reports it like a runtime error, and
the compile banner says how long it took:

```text
FAIL throws — Uncaught Error: kaput
    at main.ts:2
0 passed, 1 failed

compiled main.ts -> main (1.4s)
compiled util.ts -> util (280ms)
```

Previously the failure line leaked the Zig panic prefix ("thread 4977
panic: kaput") and the banner had no timing.

## Semantics

- In `lumen test` output, a failure whose message carries the runner's
  `thread N panic:` prefix is rewritten to `Uncaught Error: <message>`,
  matching how uncaught errors print in `lumen run` (spec 228). The `.ts`
  location line still comes from the panic's stack frame.
- `lumen compile` measures wall time (monotonic clock) across the whole
  pipeline — parse, check, emit, and the native backend — and appends it to
  the success banner: `(NNNms)` under a second, `(S.Ds)` above.
  `lumen run` stays quiet as before.

## Success Criteria

- **SC-001**: A test hitting `throw new Error("kaput")` reports
  `Uncaught Error: kaput` with the throw's `.ts` line.
- **SC-002**: `lumen compile` prints a duration; `lumen run` prints nothing
  extra.
- **SC-003**: `zig build` and `zig build test` stay green.

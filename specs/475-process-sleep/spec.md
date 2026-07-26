# Spec 475: process.sleep

## Goal

Pause the current thread for a number of milliseconds.

```ts
process.sleep(250);
```

A worker that polls a queue has to wait between polls. Without this the only
pause available is `setTimeout`/`setInterval` (spec 038), which schedules on
the event loop and therefore cannot be used to space out the iterations of a
plain loop — the loop never yields, so the timer never fires. The program is
then written around the hole: a `while (true)` becomes an interval callback,
and because a throw does not cross a lambda boundary that callback needs its
own `try`. That is a lot of reshaping to avoid one missing call.

Found while writing the agents package's indexing worker, which drains a
PostgreSQL job queue and must not spin.

## Semantics

`process.sleep(ms: int): void` blocks the calling thread for `ms`
milliseconds against the *awake* clock, so a suspended machine does not count
its suspension as elapsed time.

Zero and negative durations return immediately rather than failing. A caller
computing a delay — `sleep(deadline - now())` — should not have to guard the
case where the deadline has already passed; refusing it would only move that
guard into every caller.

It does not throw. Sleeping is not an operation with a failure a program can
act on: an interrupted sleep has already waited, and a caller that cares about
elapsed time reads the clock rather than a return value.

Node exposes no synchronous sleep at all (`setTimeout` only, plus
`Atomics.wait` as a workaround), so this is named for what it does rather than
copied. It sits under `process` beside `cwd`, `chdir`, `exit` and `env` —
the namespace for "this process" operations — rather than under `timers`,
which is the event loop's.

## Success Criteria

- **SC-001**: `process.sleep(250)` pauses for at least 250ms as measured by
  `Date.now()` either side.
- **SC-002**: `process.sleep(0)` and `process.sleep(-5)` return immediately
  and do not error.
- **SC-003**: A non-integer argument is `E_TYPE_MISMATCH`; the wrong number of
  arguments is `E_ARG_COUNT`.
- **SC-004**: The call does not make its enclosing function throwing — a
  function whose only statement is `process.sleep(1)` stays `() => void` and
  so remains usable as a `Worker.run` body.

## Implementation

- `src/lumen_check_stdlib_os.zig` — `processCallType` accepts `sleep` with one
  integer argument, sets `uses_io` and `needs_process_api`, returns `.void`.
- `src/lumen_emit_static.zig` — emits `__processSleep(__io, <ms>)`.
- `src/lumen_runtime_os.zig` — `__processSleep` calls
  `io.sleep(std.Io.Duration.fromMilliseconds(ms), .awake)`, returning early for
  non-positive values and swallowing the cancellation error, since the
  signature is `void`.

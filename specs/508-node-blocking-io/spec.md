# Spec 508: blocking I/O and threads on the Node target

**Status**: Draft — decision spec with a spike; not scheduled until 504–506
are green | **Parent**: 501, slice 4

## What must be true for the rest of Joule to run

Lumen's I/O is synchronous and its concurrency is real threads:

| Surface | Spec | Semantics |
| --- | --- | --- |
| `Socket.read()`, `net.connect` | 054 | blocks for the next chunk |
| `net.createServer(port, handler)` | 054, 490 | one OS thread per accepted connection; handlers share module state (468, 492 made that safe) |
| `http.request`, `http.stream(...).read()` | 042, 452 | blocking |
| `http.createServer` | 042, 355 | thread per request |
| `child_process.spawn(...).readLine()` | 450 | blocking |
| `process.sleep(ms)` | 475 | blocks the thread |
| `Worker.run(fn)` | 059 | a thread; scalar result via a promise |
| `readline.question` | 058 | blocks |

Node offers one thread per isolate and no synchronous socket read.

## The constraint that decides it

Handlers share the heap. A `net.createServer` handler in Joule's relay
mutates module-level Maps that other handlers read. Two Node designs each
keep half of this:

- **Handlers on `worker_threads`, blocking via `Atomics.wait` against an
  I/O broker on the main thread.** Keeps every blocking signature. Loses
  shared state: workers have separate heaps, so a Map updated in one handler
  is invisible to another. Programs that only share immutable state, or
  none, run unchanged; the relay does not.
- **Handlers on the main thread, blocking calls as `Atomics.wait` on a
  broker that lives in a worker.** Keeps shared state. Loses concurrency:
  while one handler waits in `socket.read()` no other handler runs, which is
  exactly the spec 490 bug on Node.

There is no third design that keeps both without changing what the source
means. So:

## Decision

1. **`process.sleep`, `readline.question`, `spawn(...).readLine()`,
   `http.request`, `net.connect`+`Socket.read()` on the main program's
   thread**: implement with a worker-hosted broker and `Atomics.wait`. The
   caller is the single main thread, so nothing is lost. This covers Joule's
   CLI (`code.ts`): it polls with `sleep`, talks to the model with
   `http.stream`, and drives subprocesses with `readLine`.
2. **`Worker.run(fn)`**: a `worker_threads` Worker running the emitted module
   with `fn` selected by name; scalar result only (059 already restricts
   `T`). Captured scalar bindings are copied in, as natively. Module state is
   *not* shared, which 059's restriction to scalars already implies is the
   intended contract.
3. **`net.createServer` / `http.createServer` handlers**: rejected on the
   Node target with `E_TARGET_UNSUPPORTED` naming this spec, until the
   language has a server API whose handlers do not block. That API is a
   language decision (an `async` handler form, which 479 makes coherent),
   to be its own spec; it must land on the native target first so both
   targets run the same program.

The consequence for Joule: `joule` (the CLI) and `joule-daemon`'s worker
paths run on Node after this spec; `relay` and the daemon's listening side
wait for the server-API spec. That is stated in Joule spec 004.

## Spike (do before scheduling)

A 300-line prototype in `packages/node-runtime/spike/`:

- broker worker: owns real sockets/processes/timers; protocol over a
  `SharedArrayBuffer` ring (request id, op, args as bytes; response as
  bytes).
- main thread: `Socket.read()` = post request, `Atomics.wait` on the slot,
  copy bytes out.
- measure: latency per call, throughput of a 64 KB read loop, and whether
  `console.log` and timers on the main thread survive a long wait (they
  should not; the point of the design is that the main thread *is* blocked,
  as natively).

Outcome recorded here before 508's tasks are written.

## Success criteria (once scheduled)

- **SC-001**: Joule `code.ts` compiles with `--target node` and drives a
  stub model end to end (`scripts/e2e_full_stack.mjs` with the node build).
- **SC-002**: `process.sleep(250)` measures ≥ 250 ms; a `readLine()` loop
  over `spawn("cat")` round-trips 10k lines.
- **SC-003**: `net.createServer` on the Node target reports
  `E_TARGET_UNSUPPORTED` with this spec's name.

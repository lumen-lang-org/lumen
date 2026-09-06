# Spec 508: blocking I/O and threads on the Node target

**Status**: Spike done, ready to schedule (see `tasks.md`) | **Parent**: 501, slice 4

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

## Spike (done)

A 304-line prototype in `packages/node-runtime/spike/`
(`protocol.mjs`, `broker.mjs`, `sync_bridge.mjs`, `proc_server_client.mjs`,
`dump_server_proc.mjs`, `measure.mjs`), run with plain `node measure.mjs`.

**Design confirmed.** The broker worker owns a real `net.Socket` and real
timers; the shared memory is a fixed control block (`Int32Array(6)`: state,
request id, op, arg length, response length, response status) plus a data
region, sized past the 64 KB chunk spec 054 documents. The main thread
posts a request, calls `Atomics.wait` on the state word, and copies bytes
out once notified — the broker never touches `Atomics.wait` itself (that
would block its own event loop); it uses `Atomics.waitAsync` to be notified
of a new request while its real sockets/timers keep running underneath.

**Two non-obvious Node behaviours the spike exists to catch, found early
rather than mid-implementation:**

1. **`Atomics.waitAsync`'s promise does not keep a worker's event loop
   alive.** It corresponds to no libuv handle, so a worker with nothing
   else pending exits right after registering the wait — before any
   `Atomics.notify` can ever reach it. Fix: an inert long-period
   `setInterval` in the broker holds the thread open between requests.
   Undiagnosed, this would have looked like "the bridge randomly doesn't
   respond" depending on what else the broker happened to be doing.
2. **Every socket listener must be attached in the same synchronous turn
   that creates the socket**, not after `await`ing a connect promise. A
   fast peer (write immediately, then end — exactly what the measurement's
   own dump server does) can deliver data and EOF before a promise
   continuation (a microtask) gets to run, so listeners added one tick
   later can miss both. The working version registers `data`/`end`/`error`
   handlers on the same line the socket is constructed and waits for
   `connect` through the same wake mechanism reads use.

**Measured** (three runs, this container; a genuine peer process each time —
see note below on why the peer cannot be in-thread):

| Measurement | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- |
| Round-trip latency, 500× `sleep(0)` | 1.35 ms/call | 1.34 ms/call | 1.34 ms/call |
| `sleep(250)` actual duration | 250.66 ms | 250.59 ms | **249.66 ms** |
| Main-thread 10ms-interval ticks during the 250ms block | 0 | 0 | 0 |
| 8 MB read loop, direct socket (no bridge) | 816.6 MB/s | 803.4 MB/s | 768.4 MB/s |
| 8 MB read loop, bridged (119 calls) | 23.3 MB/s | 49.6 MB/s | 41.0 MB/s |
| Bridge overhead | 35.0x / 2.80 ms per call | 16.2x / 1.27 ms per call | 18.7x / 1.55 ms per call |

**The load-bearing result**: 0 ticks, every run. A 10ms `setInterval` armed
on the main thread before a 250ms bridged sleep never fires during the
block and resumes immediately after — direct evidence the main thread is
genuinely blocked for the call's duration, not merely appearing to wait
while its own event loop quietly keeps running. That is the property this
whole design exists to deliver, and it holds.

**Two findings for the real implementation, not just the spike:**

- **Run 3's `sleep(250)` undershot by 0.34 ms.** The broker's
  `setTimeout(r, ms)` plus the round-trip's own overhead doesn't strictly
  guarantee "at least `ms`" the way spec 475 requires; timer rounding at
  the millisecond boundary can land a hair short. 508's real
  `process.sleep` needs to measure elapsed time in the broker and re-arm a
  short follow-up timer if it undershoots, rather than trusting one
  `setTimeout` call. Caught here, before it became a flaky conformance
  case.
- **Throughput overhead is real and worth measuring against Joule's actual
  traffic, not assumed away.** 13–35x wall-clock time and roughly
  1.3–2.8 ms per call over a loopback socket. `http.stream`'s response
  bodies (452) and `child_process.spawn`'s `readLine()` (450) both read in
  a similar per-chunk loop; the per-call cost, not the raw MB/s number
  (dominated by this container's own scheduling noise across runs), is the
  number to budget against. The prototype serializes call arguments with
  `JSON.stringify`/`JSON.parse`, which is on this path for every call — a
  tighter binary encoding is a legitimate first place to look if a real
  workload finds this cost noticeable.

**Why the dump server is a separate OS process, not a same-process
peer**: the first version of this measurement put the test server on the
main thread. It deadlocked — the main thread's own `Atomics.wait` blocked
before the server's `'connection'` handler ever ran, since that handler
needed the very event loop turn the wait was consuming. That failure mode
generalizes past this spike: in real use, `net.connect`'s or
`http.request`'s peer is never the calling thread (a remote API, a local
daemon on its own process), so a same-thread peer wasn't a stand-in for
anything real. Recorded here because a task or test for 508 that tries to
exercise the bridge against a same-process server will hit the identical
deadlock for the identical reason.

## Success criteria (once scheduled)

- **SC-001**: Joule `code.ts` compiles with `--target node` and drives a
  stub model end to end (`scripts/e2e_full_stack.mjs` with the node build).
- **SC-002**: `process.sleep(250)` measures ≥ 250 ms; a `readLine()` loop
  over `spawn("cat")` round-trips 10k lines.
- **SC-003**: `net.createServer` on the Node target reports
  `E_TARGET_UNSUPPORTED` with this spec's name.

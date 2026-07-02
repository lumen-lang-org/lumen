# Spec 047: async fs beyond the readFile/writeFile/appendFile trio, via a real thread pool

## Goal

Ship genuine, cross-platform async versions of a representative set of
`fs.*` functions beyond the existing `readFile`/`writeFile`/`appendFile`
trio -- `fs.unlink(path) -> Promise<void>`, `fs.mkdir(path) -> Promise<void>`,
`fs.rmdir(path) -> Promise<void>`, `fs.stat(path) -> Promise<Stats>` -- using
a real worker thread pool, not a Linux-only shortcut.

## Why the existing trio doesn't generalize, and why this needed real
## investigation before a design was possible

`fs.readFile`/`writeFile`/`appendFile` are true async on `libxev`'s
io_uring backend: `xev.File.pread`/`pwrite` submit real io_uring SQEs, no
thread involved. The natural instinct for "more async fs" is to keep doing
that -- but checked directly (`OperationType` enum in
`libxev/src/backend/io_uring.zig`) and it only supports:
`accept`/`close`/`connect`/`poll`/`read`/`pread`/`recv`/`send`/`sendmsg`/
`recvmsg`/`shutdown`/`pwrite`/`write`/`timer`/`timer_remove`/`cancel`. No
`unlink`/`mkdir`/`stat`/`rename`/`chmod` op exists at that layer, even
though io_uring itself supports all of those (`IORING_OP_UNLINKAT`,
`IORING_OP_MKDIRAT`, `IORING_OP_STATX`, ...) -- `libxev` simply doesn't wrap
them into its cross-platform `Operation` union.

**A Linux-only path exists and was considered first**: `xev.Loop.ring` (the
underlying `std.os.linux.IoUring`) is a public field, and Zig's own
`IoUring` wrapper already has `unlinkat`/`mkdirat`/`statx`/`renameat`
methods ready to use -- submitting directly onto the same ring the event
loop already drives, no thread pool needed. Explicitly **not** the design
here: it's Linux-only, and the project targets macOS and Windows release
binaries too (see the `release.yml` CI matrix). A cross-platform-first
design was prioritized over the faster but narrower one.

**The actual cross-platform design, verified directly against `libxev`
source rather than assumed**:

- `libxev/src/ThreadPool.zig` is a real, generic, standalone worker-thread
  pool (`Task`/`Batch`/`schedule`) with **no OS-specific integration** --
  it doesn't care which backend (io_uring/kqueue/iocp) the loop uses.
- `libxev`'s own `kqueue.zig` backend **already uses this internally**:
  macOS/BSD's kqueue has no native completion-based filesystem I/O, so
  `libxev` falls back to running blocking file ops on this same
  `ThreadPool` and delivers results back to the main loop via a
  `thread_pool_completions` queue. This is production-tested machinery,
  not a theoretical capability -- `libxev` depends on it for its own
  correctness on macOS.
- `xev.Async` ("wake up an event loop from any thread") has a **dedicated
  implementation for every backend** (checked the dispatch in
  `watcher/async.zig`): `AsyncEventFd` for io_uring/epoll, `AsyncMachPort`
  for Darwin kqueue (`AsyncEventFd` for BSD kqueue), `AsyncLoopState` for
  `wasi_poll`, and `AsyncIOCP` for Windows. This is the genuinely portable
  primitive -- confirmed present on all three real release targets
  (Linux/macOS/Windows).
- `iocp.zig` (Windows) has **no** `ThreadPool` references and no
  `unlink`/`mkdir`/`stat` operation types either -- same gap as io_uring/
  kqueue at the native-op level. So the design below doesn't lean on any
  backend-specific fallback machinery (like kqueue's internal
  `thread_pool_completions` wiring, which isn't exposed at the `Loop`
  level in a way arbitrary Lumen tasks could hook into anyway) -- it
  assembles its own thread pool + wake-up bridge from `libxev`'s public
  primitives, the same level of integration Lumen's generated code already
  has with `libxev` everywhere else (it calls public watcher APIs, it
  doesn't reach into backend internals).

## Design

```
Lumen thread pool call site (e.g. __unlinkAsync)
  -> creates a LumenPromise(T)
  -> builds a ThreadPool.Task whose worker-thread body:
       - does the blocking syscall (e.g. std.Io.Dir.cwd().deleteFile)
       - stores the raw result on a heap-allocated completion record
       - pushes that record onto a thread-safe MPSC queue
       - calls the shared xev.Async handle's .notify()
  -> schedules the task via the shared ThreadPool.schedule(...)
  -> returns the promise immediately (matching every other async builtin)

Main thread (already running __xev_loop.run(...) via LumenPromise.await_/
LumenLoop.drain):
  -> the shared xev.Async's registered .wait(...) callback fires
  -> drains the MPSC queue
  -> for each record, calls record.finish(record) -- a per-op-type callback
     that unpacks the raw result and calls promise.resolve(...)
```

**Why route through a queue instead of calling `promise.resolve()` directly
from the worker thread**: `LumenPromise.resolve()` is a plain, non-atomic
field write (`resolved: bool`, `value: T`), and `.await_()`/`LumenLoop.drain`
poll it from the main thread while pumping `__xev_loop.run()`. Calling
`.resolve()` directly from a worker thread would be a real, unsynchronized
data race against that poll. Keeping `.resolve()` exclusively main-thread-
only (called only from inside the `xev.Async` wake-up callback, which -- like
every other `libxev` callback -- runs on the thread that calls
`__xev_loop.run()`) means the existing `LumenPromise` implementation needs
**zero changes**; only the queue itself needs thread-safe push/pop (a small
mutex-protected `std.ArrayListUnmanaged`, given the low expected concurrency
of filesystem ops relative to a hot network path).

**One shared `ThreadPool` and one shared `xev.Async`** per program, created
once alongside the existing `__xev_loop` in `LumenLoop.init()`, not one per
call -- matching how a real event loop runtime is meant to be used, and
avoiding the overhead of spinning up worker threads per fs call.

## API (v1 scope)

| Function | Type | Notes |
| --- | --- | --- |
| `fs.unlink(path)` | `string -> Promise<void>` | |
| `fs.mkdir(path)` | `string -> Promise<void>` | no `recursive` option this pass, matching `mkdirSync`'s default-false convention |
| `fs.rmdir(path)` | `string -> Promise<void>` | |
| `fs.stat(path)` | `string -> Promise<Stats>` | reuses `__LumenStat`, the same record `fs.statSync` already returns |

Deliberately small: four functions chosen to prove the thread-pool + wake-up
pattern works correctly and portably, not to cover Node's whole async
surface in one pass. Every additional async fs function after this is
mechanically the same shape (wrap one blocking syscall in a `Task`), so this
is the hard part -- extending the list afterward should be materially
cheaper per function.

## Requirements

- **FR-001**: `ThreadPool`/`xev.Async` are created once per program, shared
  across every thread-pool-backed async fs call.
- **FR-002**: `LumenPromise.resolve()` is only ever called from the main
  thread (inside the `xev.Async` wake-up callback), never directly from a
  worker thread.
- **FR-003**: The completion queue is genuinely thread-safe (mutex-protected
  push from worker threads, pop from the main thread only).
- **FR-004**: Each of the four v1 functions is verified against real
  filesystem state (not just "doesn't crash") -- e.g. `fs.unlink`'s promise
  resolving must correspond to the file actually being gone on disk by the
  time `await` returns, `fs.stat`'s resolved value must match `statSync`'s
  on the same path.
- **FR-005**: A test that awaits multiple concurrent thread-pool-backed
  calls (e.g. several `fs.unlink`s in flight at once) must resolve all of
  them correctly -- proving the queue handles more than one in-flight
  completion, not just the single-call case.
- **FR-006**: `zig build test` and a full, clean, non-concurrent
  `zig build conformance` run must show no regressions, including to the
  existing `readFile`/`writeFile`/`appendFile` trio (which must keep using
  their existing io_uring-direct path, not be accidentally routed through
  the new thread pool).

## Not planned (this pass)

| Item | Why |
| --- | --- |
| Every other Node async fs function (`rename`, `chmod`, `chown`, `readdir`, `copyFile`, ...) | mechanically the same pattern as the four shipped here; deliberately scoped small to prove the pattern first |
| `fs.promises.*` (the Promise-returning namespace itself, as opposed to `fs.fn(path) -> Promise<T>` top-level functions) | naming/namespacing question, orthogonal to the async mechanism itself |
| Skipping the thread hop on Linux via direct io_uring SQEs (the path considered and set aside above) | a real, valid performance optimization for a future pass, once the portable baseline exists and is proven correct |
| Cancellation, backpressure, a bounded queue depth | not exercised by the v1 function set (each is a single quick syscall, not a long-running operation) |

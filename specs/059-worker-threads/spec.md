# Spec 059: worker_threads (real CPU parallelism)

## Goal

Give Lumen a way to run CPU-bound work on a real, separate OS thread and
get a result back -- the gap Node's `worker_threads` fills, checked
directly against Node's own current docs
(`nodejs.org/api/worker_threads.html`), which Lumen's stdlib had no
equivalent for. Unlike most stdlib gaps, this one is a genuinely good fit
for Lumen's architecture: Lumen compiles to a single native binary with
real OS threads (no V8-isolate-per-thread overhead Node pays), so a
Worker maps directly onto a real `std.Thread` running a Lumen function.

## Why Node's actual API can't be copied literally

Node's `new Worker(filename)` loads and runs a **separate script file** in
an isolated realm -- a second entry point into the same JS engine. Lumen
has no equivalent concept: `lumen compile` produces one static native
binary from one program; there is no second module file to dynamically
load at runtime, no module loader, no second V8-realm-equivalent to
isolate global state into. This is the same reason spec-adjacent research
flagged `child_process.fork`/`cluster` as hard for Lumen ("needs a
redesigned launch-another-entry-point concept since Lumen has no
JS-module-to-fork-into") -- copying the file-based constructor shape
would be incoherent, not just awkward.

**The honest adaptation**: a Worker takes a **Lumen function value**,
already a real first-class value in this language, not a file path.
Confirmed directly from the compiler rather than assumed: function-typed
values lower to a fat-pointer struct per distinct signature (`funcStructName`
in `src/lumen_types.zig:156-185`, emitted as `const LumenFn_..._ = struct {
ctx: *const anyopaque, call: *const fn (*const anyopaque, ...args) R };` in
`src/lumen_compiler.zig:273-283`), and every call through a function value
already lowers to `f.call(f.ctx, args...)` (`src/lumen_emit.zig:233-241`).
`LumenEventEmitter`'s listener storage (`src/lumen_compiler.zig:389-447`,
storing `{ctx, call, once}` and invoking via `l.call(l.ctx, value)`) is the
closest existing precedent in this codebase for "store a callback, invoke
it later" -- Worker's runtime state struct follows the same shape.

## Design decisions

### Constructor shape: `Worker.run(fn)`, not `new Worker(fn)`

A static, one-shot namespace call, not a builder/class. Node's `Worker` is
a stateful class because it needs an event-based lifecycle
(`worker.on('message', ...)`, `.postMessage()`, `.terminate()`) for a
long-lived entity that loaded a whole separate program. Lumen's version is
a single request/response operation -- spawn, run one function, get one
result -- which is exactly the shape this stdlib's existing one-shot
builtins already use (`Buffer.from`/`.alloc`, `zlib.gzipSync`,
`fs.readFile(path) -> Promise<string>`), not the OO/builder shape this
codebase has consistently avoided. `new Worker(...)` would imply a
reusable, message-passing object Lumen has no mechanism for yet (no
`postMessage`, no cross-thread mutable channel) -- shipping half of that
shape (a constructor with none of the instance methods) would be worse
than not having the OO shape at all.

### Signature: `Worker.run(fn: () => T): Promise<T>`, `T` restricted to `i32 | i64 | f64 | bool`

No separate "input argument" parameter. Input flows in via Lumen's
existing closure-capture mechanism (an arrow capturing an outer `let`, or
a plain top-level function with no captures at all) -- Lumen already has
exactly one mechanism for "getting a value into a callback" and this
reuses it rather than inventing a second, parallel one (e.g. a
`workerData`-style parameter Node needs because its worker loads a
*different program* with no lexical access to the caller's scope; Lumen's
Worker function is defined in the *same* program and already closes over
whatever it needs).

`T` is checker-enforced (`workerCallType` in
`src/lumen_check_stdlib.zig`, following the same shape as
`bufferCallType`/`fsCallType`) to be exactly one of the four scalar types.
Not a guess -- the narrowing is driven by the thread-safety investigation
below: scalars are the only case verified safe to hand back across the
thread boundary without a deeper capture-safety analysis this pass isn't
scoped to do. Every other stdlib narrow-v1 precedent (zlib picking one
compression format, Buffer picking three encodings) narrows for the same
reason: ship a small, fully-verified surface rather than a broad,
partially-verified one.

### Result handback: `Promise<T>`, via spec 047's exact worker-notifies-main pattern

`LumenPromise<T>` already exists and integrates with `await` via the main
event loop (`LumenLoop.driveUntil` polls `isResolved` while pumping
`__xev_loop.run(.once)`). Spec 047 (async fs via a thread pool) already
proved the correct, safe way to resolve a promise from background-thread
work under Lumen's *polling* (not stackless-coroutine) `await`:
`LumenPromise.resolve()` is a plain, non-atomic field write, raced against
the main thread's poll if called directly from a worker thread. So a
Worker's background thread never calls `.resolve()` -- it pushes a
completion record onto a dedicated, mutex-protected queue
(`__worker_done_queue`) and wakes a dedicated `xev.Async` handle; only the
main-thread wake-up callback (`__workerOnWake`, running on whichever
thread calls `__xev_loop.run(...)` -- always the main thread, like every
other `libxev` callback) drains the queue and calls `.resolve()`. This
means `LumenPromise` itself needs **zero changes** -- verified sound by
inspection of spec 047's identical reasoning, not re-derived from
scratch, and reusing the same `std.Io.Mutex`/`xev.Async` shapes rather
than introducing new ones.

### Thread source: bare `std.Thread.spawn` + `.detach()` per call, not `xev.ThreadPool`

Real decision, not a cargo-culted copy of spec 047's `ThreadPool`
machinery. Checked both existing precedents before choosing:

- Spec 047 (async fs) and spec 049 (concurrent `http.createServer`) both
  use `xev.ThreadPool` -- a fixed, `std.Thread.getCpuCount()`-sized pool
  of worker threads (confirmed via `libxev/src/ThreadPool.zig`), meant for
  **many small, quick, blocking operations** (a syscall per fs call, one
  connection's request/response cycle per HTTP client) where a bounded
  pool and queuing behind it is the *correct* trade-off.
- `Worker.run` models something different: Node's own docs describe
  `worker_threads` as "useful for performing CPU-intensive JavaScript
  operations; \[workers\] will not help much with I/O-intensive work" --
  each `new Worker` is documented as one real thread, not a shared pool a
  caller queues behind. A CPU-bound Lumen worker queuing behind unrelated
  fs/HTTP-connection work on a shared bounded pool would be a real
  semantic mismatch with what a caller asked for ("run this now, in
  parallel with what I'm doing"), not just a performance detail.
- `std.Thread.spawn(config: SpawnConfig, comptime function: anytype, args:
  anytype) SpawnError!Thread` and `Thread.detach(self: Thread) void`
  (confirmed directly against `lib/std/Thread.zig` in this project's
  vendored Zig 0.16.0, not assumed from memory/older-Zig habits) are
  sufficient: one real OS thread per `Worker.run()` call, detached so the
  caller doesn't need to join it (matching every existing fire-and-forget
  background-thread shape already in this codebase -- fs's `ThreadPool`
  workers and `http`'s per-connection threads are never joined by the
  main thread either).

`xev.Async` (the wake-up bridge) is still used -- that part of spec 047's
design is thread-*source*-agnostic; a `std.Thread`-spawned worker still
needs a way to safely notify the polling main thread, and `xev.Async` is
the same portable primitive already verified (spec 047) to have a
dedicated implementation on every real release target (`AsyncEventFd`
io_uring/epoll/BSD-kqueue, `AsyncMachPort` Darwin, `AsyncIOCP` Windows).

### Thread-safety boundary: what's actually safe here, verified rather than assumed

This mattered enough to check against the actual Zig 0.16.0 std source
rather than trust habits from other Zig versions or other languages,
since Lumen has no borrow checker and no `Send`/`Sync` distinction at all.

- **The allocators are not the risk.** `std.process.Init.arena` (Lumen's
  `__alloc`) is documented directly in `lib/std/process.zig`: "Permanent
  storage for the entire process... **Threadsafe.**" Reading
  `lib/std/heap/ArenaAllocator.zig`'s `alloc` confirms this isn't just a
  doc comment: Zig 0.16's `ArenaAllocator` uses lock-free atomic
  cmpxchg/RMW operations on its node list rather than assuming
  single-thread use, and is safe "given that `child_allocator` is
  threadsafe as well" -- true for both `__alloc` (backed by the process's
  own threadsafe gpa/mmap path) and `__sa()` (an `ArenaAllocator` over
  `std.heap.page_allocator`, itself thread-safe). This is exactly what
  spec 047's fs-thread-pool completion queue already relies on (appending
  to `__fs_done_queue` via `__alloc` from a worker thread, protected only
  by its own small mutex) and what Worker's own completion queue does
  too -- confirmed, not a newly-introduced assumption.
- **The real risk is shared, mutable *Lumen objects*, not the allocator
  underneath them.** `LumenMap`/`LumenSet`/`LumenEventEmitter`/`LumenBuffer`
  and class instances all mutate their own fields (`keys_.items.len`, a
  hashmap's bucket state, ...) with no synchronization at the *container*
  level, regardless of how safe the allocator backing their memory is. If
  a Worker's function body reads or mutates one of these while the main
  thread (or another Worker) does too, that's a real, silent data race --
  true of any multi-threaded program in any language without explicit
  locking, but new here because every other Lumen callback shape today
  (timers, `EventEmitter`, array callbacks, fs/http promise completions)
  ultimately only ever *runs* on the single main thread via the event
  loop, never concurrently with the code that scheduled it.
- **Closure captures make this concrete, and are not uniformly unsafe.**
  Lumen's existing closure lowering (`src/lumen_emit.zig:1194-1204`)
  copies each captured binding *by value* into a heap-allocated `Env`
  struct at the closure's creation point (`__e.* = .{ .cap = cap, ... }`).
  For a scalar capture (`i32`/`i64`/`f64`/`bool`), this is a true
  snapshot: the worker thread only ever reads its own private copy, with
  no live aliasing back to the original stack slot -- safe, and exactly
  what this spec's test programs exercise. For a *reference-shaped*
  capture (an array, `Map`/`Set`/`Buffer`, a class instance, a captured
  string whose backing bytes some other code path still mutates), the
  "copy" only copies the pointer/slice header -- the pointee is still
  the same shared, unsynchronized memory. **This is not statically
  prevented** -- doing so would need a real capture/`Send`-style analysis
  in the checker, disproportionate scope for this pass -- so it is
  documented as a known, honest hazard rather than silently allowed to
  look safe. `website/stdlib.html` calls this out explicitly, the same
  way spec 049 documented `http.createServer`'s multi-threaded-handler
  trade-off instead of solving it.

**v1 scope, stated plainly**: safe and exercised -- a zero-argument Lumen
function (named or capturing only scalars) returning one scalar. Out of
scope and not silently allowed to look safe -- passing/returning strings,
arrays, `Map`/`Set`/`Buffer`/objects/class instances across the boundary,
and capturing any reference-shaped outer binding.

### Multiple workers: one thread per `Worker.run()` call, no persistent pool

The simpler shape by default, per this codebase's convention (v1 zlib:
one format; v1 Buffer: three encodings) -- and no concrete use case in
this pass needs a reusable pool: `Worker.run` calls are independent,
one-shot, spawn-and-forget-the-thread operations, so a caller wanting N
concurrent workers just calls `Worker.run` N times (verified below with
3 concurrent calls). A persistent pool would add real complexity (a work
queue, idle-thread lifecycle, a `Worker` handle type with its own
identity) for no requirement this spec actually has; deferred, not
avoided out of laziness.

## API (v1 scope)

| Function | Type | Notes |
| --- | --- | --- |
| `Worker.run(fn)` | `(() => T) -> Promise<T>`, `T` in `{i32, i64, f64, bool}` | spawns one detached `std.Thread`, runs `fn` on it, resolves the returned promise on the main thread once it finishes |

`fn` may be a plain top-level function (no captures at all -- the safest
case) or an arrow capturing only scalar outer bindings. Marked
`stability-experimental` in `website/stdlib.html`, matching how this
stdlib flags other narrow, real-but-limited v1 surfaces.

## Requirements

- **FR-001**: `Worker.run(fn)` is checker-validated: exactly one argument,
  a zero-parameter function value, whose return type is exactly one of
  `i32`/`i64`/`f64`/`bool`; anything else is `E_TYPE_MISMATCH`/`E_ARG_COUNT`.
- **FR-002**: `LumenPromise.resolve()` for a Worker's promise is only ever
  called from the main thread (inside the `xev.Async` wake-up callback),
  never directly from the spawned worker thread -- identical invariant to
  spec 047's FR-002, re-verified for this feature's own queue/callback
  pair rather than assumed to carry over.
- **FR-003**: The worker completion queue is genuinely thread-safe
  (mutex-protected push from worker threads, pop from the main thread
  only), independent of spec 047's fs queue (Worker doesn't require fs to
  be used, and vice versa).
- **FR-004**: A real compiled program demonstrates the worker's function
  genuinely running on a different OS thread than the caller -- observed
  via an OS thread id captured inside the worker function differing from
  the main thread's id, not just "the output looked plausible."
- **FR-005**: A real compiled program demonstrates the caller is not
  blocked while the worker runs: `Worker.run` returns a `Promise`
  immediately, and other main-thread work can execute before the
  `await` on that promise, verified with a deliberately slow worker
  function and a wall-clock check.
- **FR-006**: A real compiled program spawns at least 2-3 `Worker.run`
  calls concurrently and confirms all results resolve correctly, with
  distinct, correct values per call -- not silently serialized, not
  corrupted/interleaved (mirrors spec 047's FR-005 for this feature's own
  concurrency).
- **FR-007**: `zig build test` and a full, clean, non-concurrent
  `zig build conformance` run show no regressions.

## Not planned (this pass)

| Item | Why |
| --- | --- |
| `new Worker(...)` object with `.postMessage`/`.on('message')`/`.terminate()` | needs a real cross-thread mutable message channel Lumen has no primitive for yet; shipping the constructor shape without the instance methods it implies would be worse than the flat `Worker.run` shape actually shipped |
| `workerData`-style explicit input parameter | Lumen's existing closure capture already does this job; adding a second, parallel mechanism for the same purpose isn't justified |
| Non-scalar `T` (strings, arrays, `Map`/`Set`/`Buffer`, objects, class instances) crossing the boundary | not verified safe this pass without a real capture/deep-copy-semantics analysis; scalars alone are enough to prove the thread-spawn + promise-handback mechanism works correctly, matching every other narrow, well-justified v1 in this stdlib |
| Static prevention of unsafe reference-shaped captures | would need a real capture/`Send`-style analysis in the checker; documented as a known hazard instead, the same way spec 049 documented (rather than solved) `http.createServer`'s multi-threaded-handler data-race trade-off |
| A persistent worker pool / reusable `Worker` handle | no concrete use case in this pass needs one; `Worker.run` per call is simpler and sufficient, see "Multiple workers" above |
| Worker cancellation / timeouts | not exercised by the v1 function set (each call is a single run-to-completion function, no cancellation hook exists to wire up) |
| `--wasm` support | `Worker.run` requires `program.needs_async` (for the `Promise`/event-loop machinery), which already hits the existing, pre-established wasm-vs-`@import("xev")` gate in `lumen.zig`'s `compileFile` -- no new wasm-specific handling needed or attempted |

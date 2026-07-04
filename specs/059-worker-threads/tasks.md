# Tasks: worker_threads (real CPU parallelism)

## Phase 1

- [x] T1 AST: `needs_worker: bool = false` flag on `Program`
  (`src/lumen_ast.zig`), following the existing `needs_thread_pool_fs`
  precedent.
- [x] T2 Parser: add `"Worker"` to `Parser.isStdNamespace` (`src/lumen_parser.zig`)
  so `Worker.run(...)` parses as a `static_call` rather than a
  `method_call` on an undefined `Worker` variable.
- [x] T3 Checker: `workerCallType` in `src/lumen_check_stdlib.zig`, wired
  into `staticCallType`. Validates `Worker.run(fn)`: exactly one arg, a
  zero-param function value, return type exactly one of
  `i32`/`i64`/`f64`/`bool`. Sets `call.checked_arg_type` (the scalar `T`)
  and `call.checked_type = Promise<T>`; sets `program.uses_io`,
  `program.needs_async`, `program.needs_worker`.
- [x] T4 Emit: `static_call` branch in `src/lumen_emit.zig` for
  `Worker.run` -> `__workerRun({ZigTypeName(T)}, {fn expr})`, mirroring
  `Promise.resolve`'s existing `__promiseResolved(T, ...)` shape.
- [x] T5 Runtime: `program.needs_worker`-gated block in
  `src/lumen_compiler.zig` -- `__WorkerDone`, `__worker_async`/
  `__worker_async_c`/`__worker_done_mutex`/`__worker_done_queue`,
  `__workerInit`/`__workerOnWake`/`__workerPushDone` (spec 047's queue +
  `xev.Async` shape, copied and renamed, not re-derived), and
  `__workerRun(comptime T: type, f: anytype) *LumenPromise(T)` which
  heap-allocates a `State{f, promise, result}`, spawns
  `std.Thread.spawn(.{}, State.threadMain, .{st})`, detaches it
  immediately, and returns the promise.
- [x] T6 Wire `main()`: call `__workerInit()` after `LumenLoop.init()`
  when `program.needs_worker`; extend the existing
  `needs_thread_pool_fs -> exit(0) directly` branch to also cover
  `needs_worker` (the persistent, re-arming `xev.Async` wait means
  `LumenLoop.drain()`'s `.until_done` would hang the same way spec 047
  found for fs, for the same reason).
- [x] T7 Build: `zig build` clean.
- [x] T8 Verify FR-004 (genuinely different OS thread): confirmed via the
  debug-preserve trick (temporary `std.debug.print` of
  `std.Thread.getCurrentId()` in `main()` and in `threadMain`, on a copy
  of the generated `.zig` outside the repo, reverted before committing):
  main thread id and worker thread id printed as different real OS
  thread ids for the same compiled program.
- [x] T9 Verify FR-005 (non-blocking handoff): a 200M-iteration busy loop
  worker; `time.now()` immediately before and after `Worker.run()`
  showed 0-1ms elapsed (the call returns immediately), while the full
  `await` took ~1.5s wall clock (matching the loop's real duration).
- [x] T10 Verify FR-006 (concurrency): 3 concurrent `Worker.run` calls
  (distinct hard-coded moduli 3/5/7 over 200M iterations each) all
  resolved to correct, distinct values; temporary start/end timestamp
  debug prints (same preserved-artifact technique as T8) confirmed all
  3 threads' execution windows genuinely overlap (started within the
  same millisecond, ran concurrently) rather than being serialized.
- [x] T11 Verify the safe-capture case explicitly: arrow closures
  capturing `i32`/`f64`/`bool`/`i64` outer `let`s, including one where
  the outer bindings are mutated on the main thread *after* the closure
  was created -- the worker returned the value captured at closure-
  creation time, confirming captures are a by-value snapshot, not a live
  reference (42 and 7, not 1998/1998-derived values).
- [x] T12 `zig build test` passes. Full, clean, non-concurrent
  `zig build conformance` run (206 passed / 0 failed), run in isolation
  (no other `zig build` invocation concurrently in this worktree).
- [x] T13 Updated `website/stdlib.html`: nav entry, `<h4 id="worker">`
  section, `<div class="api">` block for `Worker.run`, a
  `stability-experimental` pill, and an honest deviation callout for the
  capture-safety boundary (mirroring the `http.createServer` concurrent-
  handler callout from spec 049). Tag-balance validated with a
  `python3`/`html.parser` script -- confirmed identical to the one
  pre-existing false positive already in the file (an unescaped
  `<cwd>` placeholder inside a `path.resolve` code sample), no new
  imbalance introduced.
- [x] T14 One commit, plain factual message, no AI attribution.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: `new Worker(...)` with
`postMessage`/events/`.terminate()`, non-scalar values crossing the
thread boundary, static prevention of unsafe reference captures, a
persistent worker pool, cancellation/timeouts, `--wasm` support.

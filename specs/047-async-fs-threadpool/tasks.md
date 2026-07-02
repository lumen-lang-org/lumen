# Tasks: async fs via a real thread pool

## Phase 1

- [ ] T1 Wire up the shared runtime pieces in `LumenLoop`: a
  `libxev.ThreadPool` instance, one `xev.Async` handle, and a mutex-protected
  completion queue (`std.ArrayListUnmanaged` of a tagged-union or
  `*anyopaque` + `finish` fn pointer record). Register the `xev.Async`'s
  `.wait(...)` callback once in `LumenLoop.init()`; its body drains the
  queue and calls each record's `finish`.
- [ ] T2 `fs.unlink(path) -> Promise<void>` -- checker branch in
  `fsCallType` (mirrors `readFile`'s `program.needs_*`/`uses_io` gating),
  emit branch, and the runtime piece: a `ThreadPool.Task` whose
  worker-thread body calls `std.Io.Dir.cwd().deleteFile` (blocking, off the
  main thread), pushes a completion record, notifies.
- [ ] T3 `fs.mkdir(path) -> Promise<void>` -- same shape, `Dir.makeDir`.
- [ ] T4 `fs.rmdir(path) -> Promise<void>` -- same shape, `Dir.deleteDir`.
- [ ] T5 `fs.stat(path) -> Promise<Stats>` -- same shape, `Dir.statFile`,
  reusing `__LumenStat`'s record type and field-population logic from
  `statSync` rather than duplicating it.
- [ ] T6 Verify each against real filesystem state, not just "didn't
  crash": `fs.unlink`'s promise resolving must correspond to the file
  actually being gone by the time `await` returns (checked via a
  synchronous `existsSync` immediately after); `fs.mkdir`/`rmdir` likewise;
  `fs.stat`'s resolved value cross-checked field-by-field against
  `statSync` on the same path.
- [ ] T7 Verify concurrency: await results from several thread-pool-backed
  calls in flight at once (e.g. unlink three different files
  concurrently, confirm all three actually got deleted and all three
  promises resolved with the correct per-call outcome, not a mixed-up or
  dropped result) -- proves the queue handles more than the trivial
  single-call case.
- [ ] T8 Regression-check the existing `readFile`/`writeFile`/`appendFile`
  trio still uses its existing io_uring-direct path unaffected by the new
  thread pool machinery (no shared state accidentally reused incorrectly).
- [ ] T9 `zig build test` passes. Full, clean, non-concurrent
  `zig build conformance` run -- verify against the established
  kill-in-progress-builds-before-sync practice, not a run racing a live
  rebuild.
- [ ] T10 Confirm `--wasm` behavior explicitly (wasm has no real OS
  threads) -- either compiles and degrades to a synchronous fallback per
  call, or is documented as unsupported under `--wasm` like
  `fs.watch`/`http.createServer`, whichever is actually true once checked
  against a real wasmtime run rather than assumed.
- [ ] T11 Update `website/stdlib.html`: new `fs` entries for the four
  functions, doc note on the thread-pool architecture and its portability
  (contrast with the io_uring-direct trio), Not-planned table trimmed.
- [ ] T12 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: the rest of Node's async fs surface
(mechanically the same pattern per function once T1-T5 prove it out),
`fs.promises.*` namespacing, the Linux-only io_uring-direct optimization,
cancellation/backpressure.

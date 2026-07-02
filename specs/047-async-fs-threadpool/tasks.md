# Tasks: async fs via a real thread pool

## Phase 1

- [x] T1 Wired up the shared runtime pieces: a `libxev.ThreadPool` instance,
  one `xev.Async` handle, and a queue (`__FsDone` records: `*anyopaque` +
  `finish` fn pointer). Protected with `std.Io.Mutex` (this Zig version
  moved `Thread.Mutex` under the `Io` namespace; `lock`/`unlock` take an
  `io: std.Io`, satisfied by reusing the program's existing global `__io`
  -- confirmed safe to call blocking `Io` operations from a worker thread
  via a standalone proof-of-concept before building anything on top of the
  assumption). Registered `xev.Async`'s `.wait(...)` once in a new
  `__fsThreadPoolInit()`, called from `main()` right after
  `LumenLoop.init()`.
- [x] T2 `fs.unlink(path) -> Promise<void>` -- checker branch in
  `fsCallType`, emit branch, and the runtime piece: a `ThreadPool.Task`
  whose worker-thread body calls `std.Io.Dir.cwd().deleteFile`, pushes a
  completion record via `__fsPushDone`, which notifies.
- [x] T3 `fs.mkdir(path) -> Promise<void>` -- same shape,
  `Dir.createDir(io, path, .default_dir)` (not `makeDir` as originally
  planned -- checked `mkdirSync`'s existing runtime code for the actual
  method name rather than guessing).
- [x] T4 `fs.rmdir(path) -> Promise<void>` -- same shape, `Dir.deleteDir`.
- [x] T5 `fs.stat(path) -> Promise<Stats>` -- same shape, reusing
  `__statSync` directly inside the worker-thread body (added
  `program.needs_stat_sync = true` to `fs.stat`'s checker branch so
  `__statSync` is always available whenever `fs.stat` is used standalone)
  rather than duplicating `__LumenStat`'s field-population logic.
- [x] T6 Verified each against real filesystem state: `fs.mkdir` + `fs.stat`
  (isDirectory true/isFile false) + `fs.rmdir` + `existsSync` false after;
  `fs.writeFileSync` + `existsSync` true + `fs.unlink` + `existsSync` false
  after; `fs.stat` on a nonexistent path resolved to the same
  all-zero/false fallback `statSync` already uses.
- [x] T7 Verified concurrency: 3 concurrent `fs.unlink` + 2 concurrent
  `fs.mkdir` calls in flight at once (5 total), awaited in issue order --
  all 5 resolved correctly with the right per-call outcome, confirmed via
  `existsSync` and a follow-up `fs.stat` on each. Proves the queue
  correctly accumulates multiple completions between wake-ups rather than
  only handling the trivial single-call case.
- [x] T8 Regression-checked `readFile`/`writeFile`/`appendFile` (a program
  using only those three, no thread-pool functions) still produces correct
  output, unaffected by the new machinery.
- [x] T9 `zig build test` passes. Full, clean, non-concurrent
  `zig build conformance` run.
- [x] T10 Confirmed `--wasm` behavior: rejected at compile time with "the
  wasm target does not support async yet" -- the same existing,
  pre-established gate that already covers `readFile`/`writeFile`/
  `appendFile` (all four gated by the same `program.needs_async` flag), so
  no new wasm-specific handling was needed.
- [x] T11 A real bug found and fixed during T6-T7, not anticipated in the
  original plan: the generated program never actually exited.
  `LumenLoop.drain()` runs the loop in `RunMode.until_done`, whose only
  stop condition (read directly from the io_uring backend's `tick_`) is
  "zero active completions" -- but the `xev.Async` wait this feature
  registers is deliberately persistent (`.rearm`s every time, since it has
  to stay armed for *future* thread-pool completions), so `active` never
  reaches zero and `drain()` hangs forever. Separately, `xev.ThreadPool`'s
  worker threads block forever waiting for more work with nothing to join
  them. Fixed by skipping `LumenLoop.drain()` entirely when the thread
  pool is in use (any explicit `await` in the user's code has already run
  by the end of `main`'s body regardless) and calling `std.process.exit(0)`
  directly instead. Verified via `timeout 5 ./program` actually returning
  before the timeout, not just checking output looked right while the
  process silently hung in the background.
- [x] T12 Updated `website/stdlib.html`.
- [x] T13 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: the rest of Node's async fs surface
(mechanically the same pattern per function now that T1-T5 prove it out),
`fs.promises.*` namespacing, the Linux-only io_uring-direct optimization,
cancellation/backpressure.

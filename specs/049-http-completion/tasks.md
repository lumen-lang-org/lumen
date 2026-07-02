# Tasks: http completion -- METHODS/STATUS_CODES and concurrent serving

## Phase 1 -- METHODS/STATUS_CODES

- [x] T1 Checker branches in `httpCallType` (`lumen_check_stdlib.zig`):
  `http.METHODS()` -> `string[]`, `http.STATUS_CODES()` -> `Map<int,
  string>` (zero-arg calls, matching `Math.PI()`/`os.EOL()`'s existing
  constant-as-zero-arg-function precedent). New `program.needs_http_constants`
  flag (`lumen_ast.zig`).
- [x] T2 Emit branches in `lumen_emit.zig`: `http.METHODS`/`STATUS_CODES`
  -> `__httpMethods()`/`__httpStatusCodes()`.
- [x] T3 Runtime codegen in `lumen_compiler.zig`, gated on
  `program.needs_http_constants`: `__httpMethods()` returns a literal
  `[]const []const u8` of the 35 real llhttp method names (checked
  directly against `deps/llhttp/include/llhttp.h`'s `HTTP_METHOD_MAP`,
  not guessed), alphabetically sorted to match Node's actual runtime
  output. `__httpStatusCodes()` builds a `LumenMap(i32, []const u8)`
  internally and `.set()`s all 63 entries from Node's real
  `lib/_http_server.js` `STATUS_CODES` object (verbatim reason phrases,
  including the apostrophe in "I'm a Teapot").
- [x] T4 Verified with a real compiled binary (not just "compiles"): a
  test program read `http.METHODS()` -- length 35, first entry `"ACL"`,
  last entry `"UNSUBSCRIBE"`, a linear scan confirming `"GET"` is present
  -- and `http.STATUS_CODES()` -- `.size == 63`, `.get(200)` ==
  `"OK"`, `.get(404)` == `"Not Found"`, `.get(418)` == `"I'm a Teapot"`,
  `.get(999)` (missing key) fell through to the `??` fallback correctly.
- [x] T5 `zig build test` passes.

## Phase 2 -- concurrent serving

- [x] T6 Threaded a `wasm: bool` field through `CompileOptions`
  (`lumen_emit.zig`) from the CLI's existing `--wasm` flag
  (`compileFile` in `lumen.zig`), so the codegen point in
  `lumen_compiler.zig` can tell which target it's generating for --
  needed because the CLI's libxev-wiring gate hard-fails any `--wasm`
  build whose generated source textually contains `@import("xev")` at
  all, and the thread-pool codegen below needs that import on native
  builds only.
- [x] T7 `needs_http_threadpool = program.needs_http_server and
  !options.wasm` gates emitting `const xev = @import("xev");` (alongside
  the existing `program.needs_async` condition) and picks which of two
  `__httpCreateServer` bodies to emit.
- [x] T8 Native body: a module-level `var __http_pool: xev.ThreadPool =
  undefined;`, assigned via `xev.ThreadPool.init(.{})` inside
  `__httpCreateServer` itself (not as the `var`'s inline initializer --
  hit and fixed a real build error: `ThreadPool.init(.{})` calls
  `std.Thread.getCpuCount()`, a runtime syscall, whenever `max_threads`
  isn't set, and Zig requires container-level `var` initializers to be
  comptime-known). Each accepted connection is heap-allocated as a `Conn`
  struct (`io`, `stream`, `handler`, and a `xev.ThreadPool.Task` field
  whose callback is `Conn.run`) and scheduled onto `__http_pool` via
  `Batch.from(&conn.task)`; `accept()` loops back immediately after
  scheduling, without waiting for the connection to be handled.
  `Conn.run` is the *exact* keep-alive inner loop the single-threaded
  version already had (request-line/header parsing, `Content-Length`
  body read, calling the handler, writing the response), moved verbatim
  onto the worker thread, then `std.heap.page_allocator.destroy(self)`
  once the connection closes.
- [x] T9 wasm body: byte-for-byte the original pre-spec-049
  single-connection-at-a-time loop, no `xev`/`ThreadPool` reference at
  all -- confirmed unaffected: `--wasm` compiles to the identical output
  size before and after this change.
- [x] T10 Verified concurrency with a real compiled binary and real
  concurrent `curl` requests from the shell (not simulated): a handler
  with a CPU-bound `/slow` path (400,000 sequential `crypto.sha256`
  calls -- chosen over an empty spin-loop specifically because a real
  function-call chain can't be silently optimized away) and a trivial
  `/fast` path. One `/slow` request in flight, a `/fast` request fired
  0.5s later completed in 0.0008s (vs. `/slow`'s own ~4.8s), proving the
  accept loop and other connections aren't blocked by an in-flight
  handler. Three concurrent `/slow` requests (each ~4.7-5s alone, which
  would be ~14-15s if serialized) all completed within ~5.1s total,
  proving genuine parallel handling across more than two connections at
  once.
- [x] T11 Regression-checked after the change, against the same real
  binary: keep-alive connection reuse (`curl -v` showing "Re-using
  existing connection"), a POST body delivered correctly to the handler,
  and a custom non-200 status code (404) from the handler all still work
  exactly as before.
- [x] T12 `zig build test` passes. `zig build conformance` run clean
  (0 failures).
- [x] T13 Update `website/stdlib.html`: `http.METHODS`/`STATUS_CODES`
  doc entries; corrected `http.createServer`'s doc note (previously
  described as single-connection-at-a-time) to describe the new
  thread-pool-backed concurrent behavior and its documented
  shared-state-race caveat; trimmed the Planned table row to reflect
  what shipped vs. what's still genuinely deferred (HTTPS/TLS
  configuration, WebSocket upgrade, streaming bodies) with real reasons.
- [x] T14 Commit (left local in the worktree for review, not pushed).

## Phase 3 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: HTTPS/TLS configuration, WebSocket
upgrade, streaming request/response bodies (network-backed, ties into
spec 046), a general-purpose locking primitive for handler-shared state,
idle keep-alive connection timeouts, real `Server`/`IncomingMessage`/
`ServerResponse`/`ClientRequest`/`Agent` classes, server lifecycle
events, client-side response headers (all unchanged from spec 042/045).

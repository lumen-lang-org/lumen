# Spec 049: http completion -- METHODS/STATUS_CODES and concurrent serving

## Goal

Close two of the five items in spec 042's "Not planned" table and
`website/stdlib.html`'s http Planned table: `http.METHODS`/
`http.STATUS_CODES` (constant data), and concurrent/multi-connection
serving (`http.createServer` currently handles one connection at a time,
even with keep-alive). The other three -- HTTPS/TLS configuration,
WebSocket upgrade, streaming request/response bodies -- are deliberately
not attempted this pass; see "Not planned" below for the real reasons.

## `http.METHODS` / `http.STATUS_CODES`

Plain constant data, the real lists Node itself uses -- not guessed:

- **`http.METHODS`**: the HTTP method name list, checked directly against
  Node's own `deps/llhttp/include/llhttp.h` (`HTTP_METHOD_MAP`), not
  against a paraphrase of it -- 35 methods (`ACL`, `BIND`, `CHECKOUT`,
  ..., `UNSUBSCRIBE`). Sorted alphabetically, matching Node's actual
  runtime `http.METHODS` value (`methods.slice().sort()`), not
  llhttp's internal declaration order.
- **`http.STATUS_CODES`**: checked directly against Node's own
  `lib/_http_server.js` `STATUS_CODES` object -- 63 entries, `100`
  through `511`, reason phrases verbatim (including the apostrophe in
  `"I'm a Teapot"`).

| Function | Type | Notes |
| --- | --- | --- |
| `http.METHODS()` | `() -> string[]` | the method name list |
| `http.STATUS_CODES()` | `() -> Map<int, string>` | status code -> reason phrase |

**Called as zero-arg functions, not properties**: Lumen has no static
namespace member/property access, only namespace *calls* -- the same
deviation `Math.PI()`, `os.EOL()`, `process.argv()` already established
for constant-shaped stdlib members. `http.METHODS`/`STATUS_CODES` follow
that exact precedent rather than inventing a new access shape for just
these two.

**`STATUS_CODES` returns `Map<int, string>`, built the same way spec 045
first proved a stdlib builtin safely can**: construct a `LumenMap`
internally (`LumenMap(i32, []const u8).__init()`), `.set()` each entry in
a loop, hand back the pointer -- the exact pattern `url.parse`'s query
field and `http`'s headers fields already use. No new capability needed,
this is the third builtin to use it.

## Concurrent serving

`http.createServer`'s accept loop was genuinely single-connection-at-a-
time: `while (true) { accept(); <fully handle this connection, including
every keep-alive request on it, until it closes>; }`. A second client
connecting while the first was still open (even idle between keep-alive
requests) simply waited for `accept()` to be called again -- which only
happened after the first connection fully finished. Spec 042 documented
this explicitly as a known gap ("Concurrent/multi-connection serving...
real concurrency (a thread/task per connection) is a separate, later
feature").

**Fix**: each accepted connection's entire handling (the existing
keep-alive inner loop, unchanged) is now handed to a worker thread from a
dedicated `libxev.ThreadPool` (`src/ThreadPool.zig` in the libxev
package), so `accept()` immediately loops back for the next connection
while earlier ones are still being served.

**Why `ThreadPool` alone, no `xev.Async`/completion queue** (unlike spec
047's async-fs-via-thread-pool design, which does need one): that design
needs a worker thread to hand a *result* back to the main thread's event
loop so a `Promise` can resolve on it. `http.createServer` is `noreturn`
and each worker's job -- read requests off its own connection, write
responses, until the connection closes -- is self-contained; nothing
needs to report back to a main thread that's itself just spinning in
`accept()`. `ThreadPool.Task`/`Batch.from`/`schedule` are enough on their
own, confirmed directly from the `ThreadPool.zig` source: a real,
generic, standalone worker-thread pool with no OS-backend integration
required (already proven in production inside libxev's own kqueue
backend, which falls back to this same pool for blocking filesystem
ops on macOS).

**A real build failure hit and fixed while implementing this**: a
`libxev.ThreadPool` instance can't be a container-level (top-of-file)
`var` with an inline initializer -- `ThreadPool.init(.{})` reads the CPU
count via `std.Thread.getCpuCount()` (a runtime syscall) whenever
`max_threads` isn't explicitly set, and Zig requires container-level
initializers to be comptime-known. Fixed by declaring `var __http_pool:
xev.ThreadPool = undefined;` at file scope and assigning it inside
`__httpCreateServer` itself, once, before the accept loop starts.

**A real wasm-compile regression risk found and avoided, not just
noticed after the fact**: the CLI's own libxev-wiring gate
(`compileFile` in `lumen.zig`) hard-fails *any* `--wasm` build whose
generated Zig source textually contains `@import("xev")` at all ("the
wasm target does not support async yet") -- checked by grepping the
generated source, not by inspecting which capability is actually used.
Unconditionally emitting the `ThreadPool`-based codegen would have broken
every existing `--wasm` compile of a program using `http.createServer`,
even though `ThreadPool` itself has nothing to do with the async event
loop that gate exists to block. Fixed by threading a `wasm: bool` through
`CompileOptions` (from the CLI's existing `--wasm` flag) down to the
codegen point, and keeping the *exact*, byte-for-byte original
single-connection-at-a-time loop -- no `@import("xev")`, no `ThreadPool`
reference at all -- for `--wasm` builds. Verified: `--wasm` compiles
identically before and after this change (same generated-binary size);
native builds now use the thread-pool version.

**Known, documented trade-off, not silently introduced**: the handler
now genuinely runs on multiple OS threads concurrently. A handler that
reads or mutates shared global state without its own synchronization now
has a real data race -- true of any multi-threaded server in any
language, but new here since Node's own `http.createServer` is
single-threaded and never has this problem. Lumen has no general-purpose
locking primitive yet, so this isn't addressed further this pass; noted
in `website/stdlib.html`.

## Verification: real concurrency, not just "didn't crash"

A handler with a CPU-bound `/slow` path (400,000 sequential
`crypto.sha256` calls, chosen because a real function call chain can't be
optimized away the way an empty spin-loop could) and a trivial `/fast`
path, run as a real compiled binary, hit with real concurrent `curl`
requests from the shell:

- One `/slow` request in flight (~4.8s to complete alone), a `/fast`
  request fired 0.5s later completed in **0.0008s** -- proving the accept
  loop and other connections aren't blocked by an in-flight handler.
- Three concurrent `/slow` requests (each ~4.7-5s alone, ~14-15s if
  serialized) all completed within **~5.1s total** -- proving genuine
  parallel handling across more than two connections, not just "the
  second request doesn't block."
- Regression-checked afterward: keep-alive connection reuse (`curl -v`
  showing "Re-using existing connection"), a POST body delivered
  correctly, and a custom non-200 status code from the handler all still
  work exactly as before.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| HTTPS/TLS-specific configuration | a real TLS binding/configuration surface beyond `std.http.Client`'s already-built-in (but unconfigurable) `https://` handling; disproportionately large scope for this pass, and orthogonal to the two items shipped here |
| WebSocket upgrade | a full protocol implementation (handshake, frame parsing/masking, ping/pong) -- a real, separate feature on the scale of `http` itself, not an extension of it |
| Streaming request/response bodies | ties into spec 046's file-backed `ReadableStream`/`WritableStream`; wiring a *network*-backed stream (a different concrete backing type than a file's reader/writer, per spec 046's own "why file-backed only" reasoning) into `http` specifically is a distinct, separately-scoped feature -- not attempted here, to keep the two required items (constants, concurrency) fully correct and verified rather than splitting time across a third, larger one |
| A general-purpose locking primitive for handler-shared state | the concurrent-serving trade-off above is documented, not solved; would need a `Mutex`-shaped stdlib addition that doesn't exist yet, out of scope for this pass |
| Idle keep-alive connection timeouts | still true from spec 042: a connection is held open indefinitely as long as the client keeps sending requests |
| `http.Server`/`IncomingMessage`/`ServerResponse`/`ClientRequest`/`Agent` as real classes, server lifecycle events, client-side response headers | unchanged from spec 042/045's own Not-planned tables -- not revisited this pass |

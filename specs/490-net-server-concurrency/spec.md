# 490 — net.createServer concurrency (fixes #11)

## Problem

`net.createServer`'s accept loop (`__netCreateServer` in
`src/lumen_runtime_net.zig`, emitted by `emitNetRuntime`) called the handler
inline on the accept loop's own call stack and only called `server.accept(io)`
again after that call returned:

```zig
while (true) {
    const stream = server.accept(io) catch continue;
    const sock = LumenSocket.__init(io, stream);
    handler.call(handler.ctx, sock);
    sock.close();
}
```

For any handler that does not return promptly — a WebSocket connection, a
chat session, a subscription, anything long-lived — this serializes the
entire server on one connection at a time, process-wide. A second client's
TCP handshake still completes (the kernel's listen backlog accepts it
independently of the application), but the server never reads from it or
answers it until the first handler returns and the loop reaches `accept()`
again. Filed as
[lumen-lang-org/lumen#11](https://github.com/lumen-lang-org/lumen/issues/11);
documented as a known, deliberate v1 limitation in spec 054's own "Not
planned" table ("no benchmark or prior request/response cadence to justify
it yet for a raw-bytes protocol").

This was already a known gap relative to `http.createServer`, which got the
`xev.ThreadPool` treatment in spec 049 (and the pool-sizing/arena fix in spec
355) specifically because keep-alive HTTP has the same shape: a handler that
does not return until the connection is done. `net.createServer` never
received the equivalent fix, so any raw-TCP server with concurrent long-lived
connections hits the ceiling `http.createServer` no longer has.

## Change

`src/lumen_runtime_net.zig`, `emitNetRuntime`: `__netCreateServer` now mirrors
`__httpCreateServer`'s thread-pool codegen exactly. Each accepted connection
is handed to a dedicated libxev `xev.ThreadPool` (`__net_pool`) as its own
task, so `server.accept(io)` is called again immediately rather than waiting
for the handler:

```zig
var __net_pool: xev.ThreadPool = undefined;
fn __netCreateServer(io: std.Io, alloc: std.mem.Allocator, port: i32, handler: anytype) noreturn {
    ...
    __net_pool = xev.ThreadPool.init(.{
        .max_threads = @max(4, __net_cpus * 2),
        .stack_size = 8 * 1024 * 1024,
    });
    ...
    while (true) {
        const stream = server.accept(io) catch continue;
        const conn = std.heap.page_allocator.create(Conn) catch { stream.close(io); continue; };
        conn.* = .{ .io = io, .stream = stream, .handler = handler };
        __net_pool.schedule(xev.ThreadPool.Batch.from(&conn.task));
    }
}
```

Gated behind a new `needs_net_threadpool = program.needs_net_server and
!options.wasm` flag, the same pattern `needs_http_threadpool` already uses:
wasm32-wasi has no real OS threads and the CLI hard-fails any wasm build that
references `@import("xev")` at all, so that target keeps the original
single-connection-at-a-time loop unchanged. `src/lumen_compiler.zig`'s xev
import gate is extended to also fire on `needs_net_threadpool`, so a program
using only `net.createServer` (no `http.createServer`, no `async`) still gets
libxev wired into its native build.

Pool sizing (`@max(4, cpus * 2)`) and stack size (8 MiB) match
`__httpCreateServer`'s current values, not spec 355's more aggressive
`@max(256, cpus * 32)` / 512 KB: no benchmark exists yet for raw `net`
servers to justify oversubscribing further, and an 8 MiB stack is the safer
default for a handler that can do arbitrary work with the socket (matches
`__httpCreateServer`'s own stack-size comment about a TLS handshake needing
more than 512 KB from inside a handler). Revisiting the pool shape the way
355 did for HTTP is a natural follow-up once there is a raw-TCP workload to
benchmark against.

Same documented trade-off `http.createServer`'s pool already carries: a
handler now genuinely runs on multiple OS threads concurrently, so a handler
that mutates shared global state has a real data race, same as any
multi-threaded server in any language.

(lumen#12 found this was two bugs, not one -- a Map/Set that detects the
overlap and fails loudly instead of corrupting or crashing unpredictably,
plus a separate dangling-key bug specific to `http.createServer`'s
per-connection arena that `net.createServer` never had, since
`Socket.read()` already copies into the persistent arena. See
specs/492-map-set-thread-safety/spec.md.)

## Verified

`zig build` and `zig build test` green.

Minimal repro: a `net.createServer` echo handler, one client (A) connected
and idle (blocked inside the handler's `sock.read()`, simulating a long-lived
connection with nothing new to say), a second client (B) connecting and
sending data while A is still open.

- Before this change: B gets no response for 3s while A is open; only after
  A disconnects does B get served. An 8-concurrent-client version shows only
  the *first* accepted connection is ever served — the rest starve
  indefinitely, not just delayed.
- After this change: B is served immediately while A is still open and idle.
  8 concurrent long-lived connections, 3 rounds of interleaved traffic across
  all 8 at once, all served correctly and promptly.

`zig build conformance`, compared against a fresh baseline built from the
same base commit: both trees pass 302/322 cases with the identical 20
pre-existing failures (sorted FAIL lists diff empty) — no new failures, no
fewer.

Downstream: `~/projects/code` (the joule relay, the project that filed #11
and worked around it with per-connection-type ports) built and its full test
suite (1109 `ok` assertions, 0 `not ok`) run clean against the patched
compiler, copied rather than modified.

## Boundary

Thread-per-connection with blocking I/O, same as `http.createServer` post-355
— not an epoll/kqueue event loop. The pool is sized conservatively (`cpus *
2`) pending an actual raw-TCP benchmark; a workload with many more
simultaneous long-lived connections than that may want spec 355's
oversubscription treatment applied here too, not attempted in this change.

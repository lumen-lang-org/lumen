# 355 — HTTP server throughput: fix worker starvation and per-request mmap

## Problem

Benchmarking `http.createServer` against Node's own `http.createServer`
(plaintext hello-world, keep-alive load) showed Lumen at ~0.65× Node and, worse,
**starving connections** under concurrent load. Two structural faults in the
generated server (`src/lumen_compiler.zig`, the thread-pool `__httpCreateServer`):

1. **Pool sized for CPU parallelism.** One `xev.ThreadPool` task per connection
   occupies its worker for the connection's entire keep-alive lifetime (blocked
   on socket reads between requests). The pool defaulted to
   `max_threads = getCpuCount()` (4), so only ~4 connections made progress; the
   rest were accepted then starved until an active one closed. Two load clients:
   one got 9819 req/sec, the other **31 req/sec**. Throughput was flat ~9.5k
   across 10/100/200 connections — a fixed worker-count ceiling, not concurrency.

2. **mmap/munmap per request.** Each request built its scratch arena with
   `ArenaAllocator.init(page_allocator)` + `deinit()` — an `mmap`+`munmap`
   syscall pair in the hot path of every request.

## Change

`src/lumen_compiler.zig`, thread-pool server codegen:

1. Size the pool for I/O concurrency, not cores:
   ```zig
   const __http_cpus: u32 = @intCast(std.Thread.getCpuCount() catch 1);
   __http_pool = xev.ThreadPool.init(.{
       .max_threads = @max(256, __http_cpus * 32),
       .stack_size = 512 * 1024,
   });
   ```
   HTTP serving is I/O-bound (workers mostly wait), so oversubscription is the
   correct shape — the same principle behind Node's epoll loop and Go's
   scheduler. The 512 KB stack keeps many idle workers' virtual-memory cost
   negligible.

2. Hoist the scratch arena out of the request loop: one arena per connection,
   `_ = conn_arena.reset(.retain_capacity)` between keep-alive requests, so
   steady state does zero allocation syscalls per request.

The single-connection (wasm) server path is unchanged — not a perf target.

## Verified

`zig build` + `zig build test` green. Load benchmark (`bench/http/`, 4-core box,
saturated with 4 parallel clients, req/sec):

| metric                         | before        | after          |
|--------------------------------|---------------|----------------|
| saturated throughput           | ~14,000       | ~27,000        |
| two-client fairness            | 9819 + **31** | 10797 + 10814  |
| vs Node `http.createServer`    | ~0.65×        | ~1.05× (ties)  |

Fairness is the headline: connections beyond the core count no longer starve.
Raw throughput now matches or slightly beats Node on plaintext hello-world.

## Boundary

Still thread-per-connection with blocking I/O, not an epoll/kqueue event loop.
The pool is large but finite; past ~256 simultaneous long-lived keep-alive
connections, further connections still queue. A true event-loop server (Lumen
already links libxev, which provides one) would remove the cap entirely — a
larger, separately-scoped rewrite, not attempted here.

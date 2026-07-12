# HTTP server benchmark — Lumen vs Node

Plaintext "Hello, World!" server, hit by a keep-alive load client. Same client
(`load.mjs`, Node) drives both servers.

**Important measurement note:** a single Node load client is single-threaded and
tops out near ~10k req/sec — it under-drives a fast server. To find real server
capacity, saturate with several clients in parallel and sum their throughput.

## Run

```sh
lumen compile --release-fast server.ts && mv server lumen-server
./lumen-server &                              # port 8081
node server.mjs &                             # port 8082 (Node baseline)

# single client (under-drives — client-bound near 10k):
node load.mjs 8081 50 5                        # port, connections, seconds

# saturated (4 clients, sum the numbers) — this is the real ceiling:
for i in 1 2 3 4; do node load.mjs 8081 25 4 & done; wait
```

## Diagnosis — why the Lumen server was slow

Two structural problems in the generated server (both now fixed):

### 1. Pool sized for CPU parallelism, not I/O concurrency → starvation

The server schedules one `xev.ThreadPool` task per accepted connection, and that
task occupies its worker for the connection's **whole keep-alive lifetime** —
blocked on a socket read between requests. The pool defaulted to
`max_threads = getCpuCount()` (4 on this box). So only ~4 connections ever made
progress; every connection beyond that was accepted, queued, and **starved**
until an active one closed.

Measured, two load clients against the old server:

```
client A: 9819 req/sec
client B:   31 req/sec   <- starved: A's 50 keep-alive conns held all 4 workers
```

Throughput was flat ~9.5k regardless of connection count (10 / 100 / 200 conns
all the same) — the signature of a fixed worker-count ceiling, not real
concurrency.

**Fix:** size the pool for I/O concurrency — `max_threads = max(256, cpus*32)`,
with a modest 512 KB per-thread stack so idle workers cost almost nothing. HTTP
serving is I/O-bound (workers mostly wait), so oversubscription is correct, the
same shape Node's epoll loop and Go's scheduler use.

After the fix, the same two-client test:

```
client A: 10797 req/sec
client B: 10814 req/sec   <- fair; both connections' work makes progress
```

### 2. mmap / munmap per request

Each request built its scratch arena with `ArenaAllocator.init(page_allocator)`
and `deinit()`d it at the end — an `mmap` + `munmap` syscall pair on **every
request**, in the hot path.

**Fix:** one arena per connection, `reset(.retain_capacity)` between keep-alive
requests. Steady state does zero allocation syscalls per request. This roughly
**doubled** saturated throughput (~14k → ~27k req/sec).

## Results after both fixes (this machine, 4 cores, req/sec)

Saturated (4 parallel clients, summed), median of 3 runs:

| server | req/sec |
|--------|---------|
| Lumen  | ~27,000 |
| Node   | ~25,000 |

Lumen now matches or slightly beats Node's `http.createServer` on this
plaintext workload — up from ~9.5k while starving connections before the fixes.

## Did this session's compiler work change server throughput?

**No.** The HTTP wins here came from fixing the *server runtime codegen* (pool
sizing + arena reuse), not from the escape-analysis / generic-inference work.
Those optimize *user CPU compute* (object churn, arithmetic loops — see
`../bench.ts`, `../bench2.ts`) and never touch the socket path. Different axis.

## Where should a body parser live? — contrib, not stdlib

Structured request-body parsing (JSON already available via `JSON.parse` on
`req.body`; urlencoded forms; multipart) belongs in a **contrib package**
imported by URL, not the native stdlib:

- **Node's own precedent.** Core `http` exposes the raw body only; `body-parser`
  is userland (Express), never built in. Lumen already matches — `req.body` is a
  plain string.
- **Policy-heavy, evolvable.** Size limits, content-type dispatch, charset
  handling, multipart boundaries — choices that should evolve in versioned
  userland, not the frozen compiled-in stdlib surface.
- **Keeps the stdlib lean.** Every binary pays for stdlib; convenience parsers
  only some servers need fit the "a package is just a URL" model.

stdlib keeps the raw `req.body` string + `JSON.parse`; form/multipart ships as
`std-contrib`.

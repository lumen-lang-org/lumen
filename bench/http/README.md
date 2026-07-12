# HTTP server benchmark — Lumen vs Node

Plaintext "Hello, World!" server, hit by a keep-alive load client. Same client
(`load.mjs`, Node) drives both servers, so the comparison is apples-to-apples
even though the client itself is single-threaded and forms a shared ceiling.

## Run

```sh
# Lumen server (port 8081)
lumen compile --release-fast server.ts && mv server lumen-server
./lumen-server &
node load.mjs 8081 50 6      # port, connections, seconds

# Node server (port 8082)
node server.mjs &
node load.mjs 8082 50 6
```

## Results (this machine, req/sec)

| connections | Lumen  | Node   | Lumen / Node |
|-------------|--------|--------|--------------|
| 10          | ~9,500 | ~14,100| 0.67×        |
| 50          | ~10,000| ~14,700| 0.68×        |
| 100         | ~9,570 | ~11,070| 0.86×        |
| 200         | ~8,660 | ~11,700| 0.74×        |

**Node is faster on this workload.** Two structural reasons:

1. **Concurrency model.** Node runs one libuv epoll event loop; Lumen's server
   (spec 049) is thread-per-connection with a blocking `accept` loop. At high
   connection counts the per-thread overhead shows (Lumen dips at 200 conns
   while Node holds flat).
2. **Parser.** Node ships llhttp, a hand-tuned C HTTP parser. Lumen's request
   parsing is straightforward Zig, not micro-optimized.

The single-threaded Node *client* caps both around 10–15k req/sec, so these
numbers understate each server's true ceiling; the *ratio* is the signal.

## Did this session's compiler work change server throughput?

**No — and it wasn't expected to.** This session shipped escape analysis
(stack-allocate non-escaping class instances) and generic inference. Those
optimize *user CPU compute* — object churn, tight arithmetic loops — where
Lumen already beats or ties Node (see `../bench.ts`, `../bench2.ts`). They do
not touch the socket accept path, the request parser, or the response writer,
so HTTP throughput is unchanged. The server is I/O- and parser-bound, not
compute-bound; the wins from this session live on a different axis.

To close the HTTP gap needs work on the server itself: an epoll/kqueue event
loop (Lumen already links libxev, which provides exactly this) instead of
thread-per-connection, and a faster request-line/header parser. That is a
separate, server-scoped effort — not something the compute optimizations reach.

## Where should a body parser live? — contrib, not stdlib

Structured request-body parsing (JSON already available via `JSON.parse` on
`req.body`; urlencoded forms; multipart) belongs in a **contrib package**
imported by URL, not the native stdlib. Reasons:

- **Node's own precedent.** Core `http` exposes the raw body only; `body-parser`
  is userland (Express middleware), never built in. Lumen already matches this:
  `req.body` is a plain string.
- **Policy-heavy, evolvable.** Body parsing carries choices — size limits,
  content-type dispatch, charset handling, multipart boundaries — that should
  evolve in versioned userland, not the frozen, compiled-in stdlib surface.
- **Keeps the stdlib lean.** The compiled stdlib is the thing every binary pays
  for; convenience parsers that only some servers need fit the "a package is
  just a URL" model.

stdlib keeps exposing the raw `req.body` string (and `JSON.parse` for the common
JSON case); form/multipart decoding ships as `std-contrib` when built.

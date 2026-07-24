# Feature Specification: Streaming HTTP

## Problem

Lumen's HTTP surface is request-in, response-out, with both sides fully
buffered. That shape is right for JSON APIs and wrong for the one workload the
std-contrib `ai` package now makes pressing: token streaming. An AI service
must *consume* a provider's server-sent-events stream (`stream: true` on
`/chat/completions`) and *serve* one to the browser, and neither direction is
possible today.

### 1. The client cannot read a response incrementally

`http.request` (`src/lumen_runtime_net.zig:26`) drives the whole exchange
through a convenience fetch that accumulates the entire body into one buffer
before returning. A caller sees nothing until the response is complete — for a
provider stream, that means every token arrives at once, after generation
finishes, which defeats streaming entirely.

The std-contrib `ai` package's MCP-over-SSE transport (`packages/ai/mcp/sse.ts`)
proves both the demand and the ceiling of the workaround: it hand-rolls HTTP/1.1
request framing, chunked-transfer decoding, and SSE frame parsing over
`net.connect`. It works — and it is restricted to `http://` because raw TCP has
no TLS, while every real provider endpoint is `https://`. Streaming from
OpenAI or Mistral is not merely awkward today; it is impossible.

### 2. The server cannot write a response incrementally

`http.createServer`'s handler returns one complete response record. The runtime
then writes `Content-Length` and the body in a single shot
(`src/lumen_runtime_net.zig`, the connection loop). There is no way for a
handler to emit an event, keep the connection open, and emit another — so a
Lumen service cannot forward tokens to a browser as they arrive. This is the
single blocker that forced the "public AI service edge must be Node" verdict;
removing it is the flip condition.

## Reproductions

### R1 — consuming a provider token stream

```ts
let headers = new Map<string, string>();
headers.set("Authorization", "Bearer " + key);
headers.set("Content-Type", "application/json");
let res = http.request("https://api.mistral.ai/v1/chat/completions", "POST",
  bodyWithStreamTrue, headers);
// res.body is the ENTIRE stream, delivered only after the model finishes.
```

Today: correct bytes, useless timing — no token is observable before the last.
Wanted: each `data: {...}` line observable the moment it arrives.

### R2 — serving server-sent events

```ts
http.createServer(8080, (req: Request): Response => {
  // one shot: no way to write an event, wait, write another.
  return { status: 200, body: "data: hello\n\n", ok: true, headers: h };
});
```

Today: `curl -N` shows nothing until the handler returns, then everything.
Wanted: each event on the wire (and flushed) at the moment the handler writes
it, with the connection held open until the handler ends it.

## Scope

In scope:

- **Streaming client.** `http.stream(url, method, body, headers)` returns a
  read handle for a response in progress, with TLS support (`https://`) and
  transparent chunked-transfer decoding, so a caller reads decoded body lines
  as they arrive.
- **Streaming server.** An `http.createServer` handler that takes a second
  parameter — a response writer — and returns nothing, writes its response
  incrementally: explicit head, then chunks flushed as written, then an
  explicit end. The existing one-parameter buffered handler is untouched.
- Response status and headers readable on the client handle (the streaming
  path builds on the lower-level request flow, which surfaces them — the
  buffered `http.request` documented them as unreachable through fetch).
- Both handler forms usable in the same program on different ports.

Out of scope:

- Streaming *request* bodies (client upload or server-side incremental read of
  a request). Token streaming needs response streaming only.
- WebSockets. SSE over chunked HTTP/1.1 covers the AI use case and is what the
  providers themselves speak.
- An async/event-callback read API (`onData(chunk => ...)`). Reads are
  blocking, like `Socket.readLine` and `ChildProcess.readLine` (spec 450);
  concurrency, if needed, comes from the existing primitives.
- HTTP/2. Providers serve SSE fine over HTTP/1.1.
- The std-contrib `ai` package's `streamChat` built on top of this — that is
  the follow-up in that repo, not part of this slice.

## Design

### D1 — `http.stream`: a client read handle

```ts
let s = http.stream(url, "POST", body, headers);  // HttpStream
s.status();            // int — from the response head
s.header("content-type"); // string — "" when absent
s.readLine();          // string — next decoded body line, blocking
s.done();              // bool — true once the stream is exhausted
s.close();             // drop the connection early
```

`HttpStream` is a synthetic named type with methods, following exactly the
`Socket` (spec 054) and `ChildProcess` (spec 450) pattern: registered lazily by
the checker, one runtime struct in the prelude.

Semantics:

- The call sends the request and reads only the response head, then returns.
  Status and headers are available immediately; the body has not been read.
- `readLine()` blocks until a full line is available, returning it without its
  terminator. Chunked transfer-encoding is decoded transparently, so the lines
  a caller sees are protocol lines (`data: {...}`, blank separators), never
  chunk-size frames. A blank line returns `""` with `done()` still false —
  blank lines are meaningful in SSE (event separators).
- At end of stream `readLine()` returns `""` and `done()` flips true; that is
  the only way to distinguish end from a separator, so loops are written
  `while (!s.done())`.
- `https://` works: the handle owns a real TLS connection for the stream's
  lifetime.

Implementation anchor: the buffered client's own comment
(`src/lumen_runtime_net.zig:48-57`) already maps the route — the lower-level
open-request / send / receive-head flow beneath `fetch`, whose response reader
decodes transfer-encoding. The streaming path uses that flow; the buffered
`http.request` stays on `fetch`, untouched.

### D2 — the two-parameter handler: a server write handle

```ts
http.createServer(8080, (req: Request, res: ResponseWriter): void => {
  res.writeHead(200, sseHeaders);  // status + headers, once
  res.write("data: one\n\n");      // chunk on the wire, flushed, immediately
  res.write("data: two\n\n");
  res.end();                       // terminates the response
});
```

The checker already validates the handler against an expected function type
(`src/lumen_check_stdlib.zig:609`); D2 makes it accept either arity — one
parameter returning a response (existing, buffered) or two parameters
returning `void` (new, streaming) — and record which form was chosen so
emission picks the matching connection loop. Same namespace call, same name,
the handler's own signature selects the mode, mirroring how Node's `(req,
res)` handler reads.

`ResponseWriter` semantics:

- `writeHead(status, headers)` writes the status line and headers with
  `Transfer-Encoding: chunked`; calling it twice is a no-op after the first.
- `write(chunk)` frames the chunk and **flushes** — immediate delivery is the
  entire point; buffering until end would rebuild the bug.
- A `write` before any `writeHead` implies `writeHead(200, {})`.
- `end()` writes the zero-length terminator chunk. Keep-alive is preserved:
  after `end()` the connection loop returns to reading the next request,
  exactly as the buffered path does.
- A handler that returns without calling `end()` has it called for it — a
  hung client is a bug, not a possible outcome.

The buffered one-parameter loop is kept byte-for-byte; the streaming loop is a
sibling, selected per server by the handler's checked arity.

### D3 — response head on the streaming client

`status()` and `header(name)` come from the received response head. Header
lookup is case-insensitive (`Content-Type` and `content-type` match), returning
`""` for an absent name — no throwing lookup.

## Success Criteria

1. R1 via `http.stream` against a local test server that writes one line per
   second: the first line is observed (printed with a timestamp) before the
   server has sent the second — arrival order proven by timing, not just
   content.
2. The same against a real `https://` provider endpoint with `stream: true`:
   `data:` lines print as tokens are generated (live check, not a conformance
   example).
3. R2 via the two-parameter handler: `curl -N` shows each event when written;
   a second request on the same connection succeeds (keep-alive preserved
   across a streamed response).
4. A Lumen proxy — streaming handler in, `http.stream` out to an upstream,
   forwarding line by line — pipes events end to end. This is the AI-service
   edge shape, in Lumen alone.
5. Chunked decoding on the client: a body whose chunk data itself contains
   `\r\n` and hex-digit-like lines round-trips intact (the hostile case
   `packages/ai/mcp/sse.ts` decodes by hand today).
6. `done()`/`readLine("")` disambiguation: an SSE body with blank separator
   lines yields the separators with `done()` false, then `""` with `done()`
   true at end.
7. The one-parameter `http.createServer` form is bit-identical in behaviour:
   every existing http example and the playground compile service pass
   unchanged.
8. `zig build test` passes; `zig build conformance` adds no new failures
   against the 169-passed / 50-failed baseline; new examples land with a
   manifest wired into `build.zig`.

## Risks

- **The lower-level client flow is a rewrite risk.** The buffered path's
  comment records that `fetch` was kept deliberately because restructuring a
  working, benchmarked call was judged too risky at the time. This spec does
  not restructure it: the streaming path is *new code beside it*. The risk
  moves to the new path only.
- **TLS connection lifetime.** The buffered client creates and tears down its
  client per call; a stream handle must keep connection, TLS state, and reader
  alive across calls and release them on `close()`/exhaustion. Leaks here are
  per-request, i.e. unbounded on a busy service — needs an explicit
  free-on-both-paths test.
- **A worker blocked on a slow stream.** A streaming *server* handler that
  itself calls `http.stream` (the proxy shape) occupies one connection worker
  for the stream's duration. The pool is already sized for I/O concurrency,
  not CPU count (spec 049) — acceptable, but document it where the
  multi-threaded-handler trade-off is already documented.
- **Handler arity overloading in the checker.** Accepting two function shapes
  for one argument is new; the diagnostic for a wrong handler (e.g. two
  params returning a response) must name both accepted forms, not fail with a
  bare type mismatch.
- **wasm32-wasi.** The single-threaded fallback server loop must gain the same
  streaming branch or reject the two-parameter form with a clear
  target-specific message — silently buffering there would be the worst
  outcome. Client `http.stream` follows whatever the wasm client can do today.
- **Flush discipline.** Every `write` must reach the socket; a buffered writer
  between the chunk frame and the wire silently reintroduces R2. The
  timing-based success criterion (#1, #3) exists to catch exactly this.

## Notes

The payoff closes the last gap in the "thin orchestrator in Lumen" story: the
ai package already covers providers, tools, RAG, memory, and MCP; with this
spec the same binary can also *be* the streaming edge, instead of delegating
that one job to a Node front. The immediate follow-up in std-contrib is
`streamChat(cfg, messages, onToken)` — parse `data:` lines and `[DONE]`, emit
deltas — plus an SSE proxy example, and rebuilding `mcp/sse.ts` on
`http.stream` deletes its hand-rolled chunked decoder and lifts its
`http://`-only restriction.

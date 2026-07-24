# Tasks: Streaming HTTP

## Investigation

- [x] Trace the lower-level client flow beneath `fetch` (open request, send,
      receive head, body reader) and confirm the body reader decodes chunked
      transfer-encoding; identify what state must live on a persistent handle
      (connection, TLS, reader buffers) for it to survive across calls.
- [x] Confirm how `Socket` (spec 054) and `ChildProcess` (spec 450) register
      their synthetic method-bearing types in the checker and emit their
      runtime structs — `HttpStream` and `ResponseWriter` follow that pattern.
- [x] Confirm where the checker validates `http.createServer`'s handler type
      (`src/lumen_check_stdlib.zig:609`) and how a second accepted shape plus
      a mode flag for emission would thread through.
- [x] Measure what the server connection loop shares between a buffered and a
      streamed response (request parse, keep-alive bookkeeping) so the
      streaming branch reuses rather than forks it.

## D1 — http.stream (client)

- [x] Checker: `http.stream(url, method, body, headers)` -> `HttpStream`;
      register the synthetic type with `status()`, `header(name)`,
      `readLine()`, `done()`, `close()`.
- [x] Runtime: send the request via the lower-level flow, read the response
      head, return the handle without touching the body.
- [x] Runtime: `readLine()` blocking, terminator stripped, chunked decoding
      transparent; `""` + `done()` false for a blank line, `""` + `done()`
      true at exhaustion.
- [x] Runtime: `https://` streams through a live TLS connection owned by the
      handle.
- [x] Runtime: `close()` and natural exhaustion both release the connection
      and TLS state — no per-request leak on either path.
- [x] Errors: connect/TLS failure yields a handle with `status() == -1` and
      `done()` true, mirroring the buffered client's `status -1` convention —
      never a crash.

## D2 — streaming server handler

- [x] Checker: accept a two-parameter `(Request, ResponseWriter) -> void`
      handler for `http.createServer` alongside the existing one-parameter
      form; record the chosen mode for emission.
- [x] Checker: a handler matching neither form fails with a diagnostic naming
      both accepted signatures.
- [x] Register `ResponseWriter` with `writeHead(status, headers)`,
      `write(chunk)`, `end()`.
- [x] Runtime: streaming connection loop — chunked head on `writeHead`
      (second call a no-op), implicit `writeHead(200, {})` on a bare `write`,
      chunk framed and **flushed** per `write`, terminator on `end()`,
      implicit `end()` when the handler returns without it.
- [x] Runtime: keep-alive preserved after a streamed response — the loop
      returns to reading the next request.
- [x] Runtime: buffered one-parameter loop untouched; both forms usable in
      one program.
- [x] wasm32-wasi: same streaming branch in the single-threaded loop, or a
      clear target-specific rejection of the two-parameter form — never a
      silent buffer.

## D3 — response head on the client

- [x] `status()` from the received head; `header(name)` case-insensitive,
      `""` when absent.

## Tests

- [x] R1 timing: local one-line-per-second server; first line observed before
      the second is sent.
- [x] R2 timing: `curl -N` (or a socket-level probe) sees each event when
      written, not at end.
- [x] Keep-alive: second request on the same connection after a streamed
      response succeeds.
- [x] Proxy: streaming handler forwarding an upstream `http.stream` line by
      line, end to end.
- [x] Hostile chunked body: chunk data containing `\r\n` and hex-like lines
      round-trips intact.
- [x] SSE disambiguation: blank separators with `done()` false, then `""`
      with `done()` true at end.
- [x] Wrong handler shapes: two params returning a response, one param
      returning void — both report the dual-signature diagnostic.
- [x] Early `close()` mid-stream releases the connection; a following
      `readLine()` returns `""` with `done()` true.

## Gates

- [x] `zig build` and `zig build test` pass.
- [x] One clean `zig build conformance` run: no new failures against the
      baseline. This branch merged spec 451 first, so the baseline is main's
      post-451 178 passed / 50 failed, not the 169 / 50 this file was written
      against. Result: 186 passed / 50 failed, the +8 being new 452 cases
      (9 total, one of which main cannot run). The 50 failing case names were
      diffed against main's and are identical.
- [x] Every existing http example and the playground compile service behave
      unchanged under the one-parameter form.
- [x] New examples land as conformance cases with a manifest wired into
      `build.zig`.
- [x] Live check (not a conformance example): `https://` provider endpoint
      with `stream: true` prints `data:` lines as tokens generate.

## Verification evidence

Arrival timing, captured on the merged branch. Content alone cannot
distinguish streaming from buffering — these are the timestamps that can.

R1, client (`manual/client_timing.ts` against `manual/sse_server.py`, one
event per second). Client line timestamps track the fixture's own send log to
the millisecond, one second apart:

```
t=1351778738 line=[data: event-0]     sent event-0 at 1351778.739
t=1351779739 line=[data: event-1]     sent event-1 at 1351779.739
t=1351780739 line=[data: event-2]     sent event-2 at 1351780.740
```

Blank separator lines came back as `""` with `done()` false between events,
then `""` with `done()` true at exhaustion — the SSE disambiguation case.

R2, server (`manual/sse_lumen_server.ts`, read with `curl -N`). Each event
reaches the client as written, a second apart, not batched at end:

```
1784899867.962 [data: one /]
1784899868.962 [data: two /]
1784899869.962 [data: three /]
```

Keep-alive across a streamed response, `curl -N .../a .../b`: curl reports
`Re-using existing connection with host 127.0.0.1`, and `/b` is served over
connection #0 after `/a` streamed to completion.

Proxy (`manual/proxy.ts`, streaming handler forwarding an upstream
`http.stream`): events emerge one second apart end to end, matching the
upstream's send cadence — a streaming edge in Lumen alone.

Hostile chunked body (`manual/hostile_client.ts`): decoded to exactly
`1a`, `not a chunk header`, `ff`, `plain line`, `0`, `tail` — chunk framing
never leaked, though the data contains hex-like lines and the fixture places
chunk boundaries mid-line so `\r\n` pairs straddle them.

Buffered form unregressed: `bench/http/server.ts` checks clean and still
answers with `Content-Length: 13`, `Connection: keep-alive` and
`Hello, World!` — a `Content-Length` response, not a chunked one.

Live provider over TLS (criterion 2), `https://api.mistral.ai/v1/chat/
completions` with `stream: true`, key from the environment:

```
status 200 at +385ms   content-type text/event-stream; charset=utf-8
+385ms data: {"id":"92bf8b3a…","object":"chat.completion.chunk",…
+420ms data: …
+455ms data: …
+492ms data: …
+528ms data: …
+974ms data: [DONE]
total data lines: 19 over 976ms
```

Chunks ~35ms apart across a real TLS connection, ending at `[DONE]` — token
arrival as generated, which the buffered client could not express at all.

## Follow-up (not this slice)

- [ ] std-contrib `ai`: `streamChat(cfg, messages, onToken)` parsing `data:`
      deltas and `[DONE]` for both wire formats, plus an SSE proxy example.
- [ ] std-contrib `ai`: rebuild `mcp/sse.ts` on `http.stream`, deleting the
      hand-rolled chunked decoder and lifting its `http://`-only restriction.
- [ ] Revisit the Node-vs-Lumen edge recommendation once criterion #4 (the
      Lumen-only proxy) holds.

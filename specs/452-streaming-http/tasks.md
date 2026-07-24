# Tasks: Streaming HTTP

## Investigation

- [ ] Trace the lower-level client flow beneath `fetch` (open request, send,
      receive head, body reader) and confirm the body reader decodes chunked
      transfer-encoding; identify what state must live on a persistent handle
      (connection, TLS, reader buffers) for it to survive across calls.
- [ ] Confirm how `Socket` (spec 054) and `ChildProcess` (spec 450) register
      their synthetic method-bearing types in the checker and emit their
      runtime structs — `HttpStream` and `ResponseWriter` follow that pattern.
- [ ] Confirm where the checker validates `http.createServer`'s handler type
      (`src/lumen_check_stdlib.zig:609`) and how a second accepted shape plus
      a mode flag for emission would thread through.
- [ ] Measure what the server connection loop shares between a buffered and a
      streamed response (request parse, keep-alive bookkeeping) so the
      streaming branch reuses rather than forks it.

## D1 — http.stream (client)

- [ ] Checker: `http.stream(url, method, body, headers)` -> `HttpStream`;
      register the synthetic type with `status()`, `header(name)`,
      `readLine()`, `done()`, `close()`.
- [ ] Runtime: send the request via the lower-level flow, read the response
      head, return the handle without touching the body.
- [ ] Runtime: `readLine()` blocking, terminator stripped, chunked decoding
      transparent; `""` + `done()` false for a blank line, `""` + `done()`
      true at exhaustion.
- [ ] Runtime: `https://` streams through a live TLS connection owned by the
      handle.
- [ ] Runtime: `close()` and natural exhaustion both release the connection
      and TLS state — no per-request leak on either path.
- [ ] Errors: connect/TLS failure yields a handle with `status() == -1` and
      `done()` true, mirroring the buffered client's `status -1` convention —
      never a crash.

## D2 — streaming server handler

- [ ] Checker: accept a two-parameter `(Request, ResponseWriter) -> void`
      handler for `http.createServer` alongside the existing one-parameter
      form; record the chosen mode for emission.
- [ ] Checker: a handler matching neither form fails with a diagnostic naming
      both accepted signatures.
- [ ] Register `ResponseWriter` with `writeHead(status, headers)`,
      `write(chunk)`, `end()`.
- [ ] Runtime: streaming connection loop — chunked head on `writeHead`
      (second call a no-op), implicit `writeHead(200, {})` on a bare `write`,
      chunk framed and **flushed** per `write`, terminator on `end()`,
      implicit `end()` when the handler returns without it.
- [ ] Runtime: keep-alive preserved after a streamed response — the loop
      returns to reading the next request.
- [ ] Runtime: buffered one-parameter loop untouched; both forms usable in
      one program.
- [ ] wasm32-wasi: same streaming branch in the single-threaded loop, or a
      clear target-specific rejection of the two-parameter form — never a
      silent buffer.

## D3 — response head on the client

- [ ] `status()` from the received head; `header(name)` case-insensitive,
      `""` when absent.

## Tests

- [ ] R1 timing: local one-line-per-second server; first line observed before
      the second is sent.
- [ ] R2 timing: `curl -N` (or a socket-level probe) sees each event when
      written, not at end.
- [ ] Keep-alive: second request on the same connection after a streamed
      response succeeds.
- [ ] Proxy: streaming handler forwarding an upstream `http.stream` line by
      line, end to end.
- [ ] Hostile chunked body: chunk data containing `\r\n` and hex-like lines
      round-trips intact.
- [ ] SSE disambiguation: blank separators with `done()` false, then `""`
      with `done()` true at end.
- [ ] Wrong handler shapes: two params returning a response, one param
      returning void — both report the dual-signature diagnostic.
- [ ] Early `close()` mid-stream releases the connection; a following
      `readLine()` returns `""` with `done()` true.

## Gates

- [ ] `zig build` and `zig build test` pass.
- [ ] One clean `zig build conformance` run: no new failures against the
      169 passed / 50 failed baseline.
- [ ] Every existing http example and the playground compile service behave
      unchanged under the one-parameter form.
- [ ] New examples land as conformance cases with a manifest wired into
      `build.zig`.
- [ ] Live check (not a conformance example): `https://` provider endpoint
      with `stream: true` prints `data:` lines as tokens generate.

## Follow-up (not this slice)

- [ ] std-contrib `ai`: `streamChat(cfg, messages, onToken)` parsing `data:`
      deltas and `[DONE]` for both wire formats, plus an SSE proxy example.
- [ ] std-contrib `ai`: rebuild `mcp/sse.ts` on `http.stream`, deleting the
      hand-rolled chunked decoder and lifting its `http://`-only restriction.
- [ ] Revisit the Node-vs-Lumen edge recommendation once criterion #4 (the
      Lumen-only proxy) holds.

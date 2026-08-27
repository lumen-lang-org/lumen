# Tasks: HttpStream.write

## Investigation

- [x] Confirm `req.connection` stays live and non-null past `receiveHead`
      today -- `__httpStreamOpen` already calls `req.connection.?.flush()`
      before returning the handle, so this is already relied on, not new.
- [x] Confirm `LumenSocket.write` and `LumenResponseWriter.write` as the
      style/error-handling template: guard nullable state, `writeAll ...
      catch return`, flush `catch {}`.
- [x] Confirm, by reading `std.http.Client`'s `Response.reader`/`bodyReader`,
      that a response with no `Content-Length` and no chunked encoding
      (a `101`'s shape) returns the raw connection reader directly --
      `readLine()` needs no change to observe bytes written after a `101`.

## Implementation

- [x] `src/lumen_runtime_net.zig`: `LumenHttpStream.write(chunk: []const
      u8): void` -- guard `self.req`/`req.connection`, `writeAll` +
      `flush`, matching `LumenSocket.write`'s error-swallowing.
- [x] `src/lumen_check_methods.zig`: `write` case in `httpStreamMethod`,
      1 string arg, returns `.void` -- same shape as `ResponseWriterMethod`'s
      `write`. This is the whole registration: `mc.container_type` set by
      `httpStreamMethod` already routes `<recv>.<name>(<args>)` straight to
      the runtime struct's method for every case in this function, so no
      separate emit-side or builtin-table entry is needed.
- [x] Doc comment above `httpStreamMethod` updated to list `write`.

## Verification

- [x] `zig build` and `zig build test` pass.
- [x] `zig build conformance`: no new failures against the pre-change
      baseline.
- [x] Manual round trip against `wss://ws.postman-echo.com/raw` (real TLS,
      real RFC 6455 handshake, public echo endpoint): `status() == 101`,
      `write()` of a hand-framed masked text frame, `readLine()` reads the
      echoed frame back byte-for-byte, `close()`/`write()` ordering (write
      then close, write after close, close after close) runs without a
      crash. See spec.md Notes for the exact byte sequences.

## Follow-up (not this slice)

- [ ] `joule-sh/code`'s relay client building a real WebSocket handshake +
      frame codec on top of this (mask/unmask, opcode handling, ping/pong)
      is that repo's work, not this one's.

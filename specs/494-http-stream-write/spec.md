# Feature Specification: HttpStream.write

## Problem

Spec 452 gave `http.stream` a read handle (`status`, `header`, `readLine`,
`done`, `close`) over a connection that already speaks TLS through
`std.http.Client`. That handle is read-only by design -- 452's scope
explicitly excluded WebSockets, so nothing needed to write back.

A consumer now does: a service that must speak `wss://` (TLS-terminated
WebSocket) to a production peer. Lumen's raw `net.connect` has no TLS at all;
adding one would mean vendoring a TLS library, out of proportion to the ask.
`http.stream` already owns a live TLS connection and already reads from it
past a `101 Switching Protocols` response (the underlying `std.http.Client`
reader falls back to the raw connection reader whenever a response carries no
`Content-Length` and no chunked encoding, which is exactly a `101`'s shape).
The read half of that already works; there is simply no way to write.

## Scope

In scope:

- `HttpStream.write(chunk: string): void` -- write raw bytes on the
  connection the handle already owns, flushed immediately.

Out of scope:

- Anything about TLS, certificate handling, or how the connection is
  established -- unchanged from spec 452.
- WebSocket framing itself. `write` hands raw bytes to the wire; a caller
  builds whatever frame it wants (mask bytes, opcode, length) and passes the
  bytes. Lumen does not know or care that the bytes are a WebSocket frame.
- A read-side change. `readLine()` already works past a `101` for the reason
  above; this spec does not touch it.

## Design

```ts
let s = http.stream(url, "GET", "", headers); // headers carry the Upgrade/Connection/Sec-WebSocket-* trio
if (s.status() == 101) {
  s.write(frameBytes);       // raw bytes onto the wire, flushed
  let echoed = s.readLine(); // the read path already reaches these bytes
}
s.close();
```

`write` mirrors `LumenSocket.write` and `LumenResponseWriter.write`: get the
handle's connection, guard it being present, `writeAll` the chunk, flush,
swallowing write/flush errors the same way those two already do (a failed
write leaves the stream in whatever state `close()` already handles safely,
same as every other method on this type).

Guarding is the load-bearing part: `write` reads `self.req` and then
`req.connection`, both optional. `close()` and natural body exhaustion both
route through `__release()`, which nulls `self.req` after tearing the
connection down. A `write` after either sees `self.req == null` and returns
immediately -- a no-op, not a use-after-free.

## Success Criteria

1. `status() == 101` observed against a real WebSocket-upgrade endpoint over
   `https://`.
2. `write()` after that `101` puts bytes on the wire -- a peer that echoes
   receives and echoes back exactly what was sent.
3. `readLine()` after `write()` observes the echoed bytes (proving the
   existing read path already reaches post-101 data, per the Design note
   above).
4. `close()` after `write()` does not crash. `write()` after `close()` does
   not crash and is a no-op. `close()` after `close()` does not crash.

## Notes

Verified manually against `wss://ws.postman-echo.com/raw` (a public
WebSocket echo endpoint, real TLS, RFC 6455 handshake): `status()` reads
101, a hand-framed masked text frame written via `write()` came back through
`readLine()` byte-for-byte, and the close/write ordering in success
criterion 4 ran clean. Not added as a conformance case: it depends on
network access to a real endpoint, which conformance runs do not have.

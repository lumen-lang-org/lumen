# Feature Specification: HttpStream.read

## Problem

Spec 494 gave `HttpStream` a `write(chunk)` -- raw bytes onto the connection
past a `101 Switching Protocols` response, enough to complete a WebSocket
handshake and send a frame. It did not add a way to read one back. The only
read primitive on `HttpStream` is `readLine()`, and it is the wrong shape for
binary WebSocket frames:

- It reads via `takeDelimiterInclusive('\n')`, which blocks until a `0x0A`
  byte shows up. A binary frame has no delimiter guarantee: length bytes, the
  masking key, and payload bytes are arbitrary, so a frame that happens not to
  contain `0x0A` never returns, and one that does returns a truncated, wrong
  "line" cut off at the first incidental `0x0A`.
- Whatever it does return is run through `std.mem.trimEnd(u8, raw, "\r\n")`,
  stripping trailing `\r`/`\n` bytes unconditionally -- corrupting binary
  payloads that legitimately end in those byte values.

There is no "read whatever is available" primitive at all, which is exactly
what WebSocket framing needs: 2 header bytes, a variable-length field, then
payload bytes, no delimiters anywhere.

## The primitive that's needed already exists -- just on a different type

`LumenSocket` (the plaintext `net.connect` path, same file) already has
exactly the right shape:

```
fn read(self: *LumenSocket) []const u8 {
    ...
    const n = self.reader.interface.readVec(&data) catch return "";
    if (n == 0) return "";
    return __sa().dupe(u8, scratch[0..n]) catch "";
}
```

One raw `recv`-style read, up to 64KB, returns whatever arrived, `""` on
EOF/closed -- no delimiter, no trimming.

## Scope

In scope:

- `HttpStream.read(): string` -- one raw, undelimited read off the same
  connection/reader `readLine()` already reaches post-101 (`self.body`,
  which is already the raw connection reader whenever a response carries no
  `Content-Length` and no chunked encoding -- exactly a `101`'s shape).

Out of scope:

- Anything about TLS, certificate handling, or `write()` -- unchanged from
  spec 494.
- WebSocket framing itself, same as spec 494's `write()`: `read()` hands back
  raw bytes, a caller parses whatever frame shape it expects.
- Any change to `readLine()`'s own behavior -- it stays exactly as it is for
  callers reading line-oriented text (SSE, protocol lines).

## Design

```ts
let s = http.stream(url, "GET", "", headers); // headers carry the Upgrade/Connection/Sec-WebSocket-* trio
if (s.status() == 101) {
  s.write(frameBytes);   // spec 494
  let raw = s.read();    // this spec -- one raw read, no delimiter, no trim
}
s.close();
```

`read()` mirrors `LumenSocket.read()` almost verbatim: guard the reader being
present, one `readVec` call into a 64KB scratch buffer, `""` on error, `""`
on a zero-length read, otherwise a fresh copy of exactly what arrived.

Guarding matches every other method on this type: `close()` and natural body
exhaustion both route through `__release()`, which nulls `self.body`. A
`read()` after either sees `self.body == null` and returns `""` immediately --
a no-op read, not a use-after-free. `read()` additionally checks `self.done_`
first (the same flag `readLine()` checks), since the two methods share one
underlying reader and one exhaustion state.

## Success Criteria

1. A masked WebSocket frame written via `write()` (spec 494) comes back
   through `read()` byte-for-byte, including a payload with embedded `\r`
   and `\n` bytes that `readLine()` would truncate and corrupt.
2. `readLine()` against that same payload demonstrably truncates it at the
   first embedded `\n` and strips trailing `\r`/`\n` -- the defect this spec
   fixes, not a hypothetical.
3. `read()` after `close()` returns `""` without crashing.
4. `read()` on a stream that never reached a `101` (a normal buffered
   response, or a connection that failed outright) behaves sanely -- no
   crash, empty or partial data as appropriate, same "fallback, don't crash"
   convention as the rest of this type.

## Notes

Verified manually against `wss://ws.postman-echo.com/raw` (a public
WebSocket echo endpoint, real TLS, RFC 6455 handshake): `status() == 101`,
`Sec-WebSocket-Accept` matched the RFC 6455 worked example, a masked frame
with an embedded-`\r\n` payload written via `write()` came back through
`read()` byte-for-byte, and the same payload through `readLine()` truncated
to 4 of the 11 wire bytes -- confirming the corruption this spec exists to
fix. Not added as a conformance case: it depends on network access to a real
endpoint, which conformance runs do not have. Same convention as spec 494.

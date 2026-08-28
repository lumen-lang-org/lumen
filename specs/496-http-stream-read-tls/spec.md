# Feature Specification: HttpStream.read over TLS

## Problem

Spec 495 gave `HttpStream` a `read()` for raw bytes past a `101 Switching
Protocols` response. It does not deliver anything over TLS, which is the only
transport the method exists for: the whole point of reading past a 101 on
`http.stream` is a `wss://` upgrade through a TLS-terminating gateway. Against
a real TLS endpoint, `status()` is `101`, `Sec-WebSocket-Accept` validates,
`write()` puts masked frames on the wire that the peer receives byte for byte
-- and `read()` returns `""` for every frame the peer sends back, as if the
body were already exhausted.

## Cause

`read()` reads with `readVec`:

```
var scratch: [65536]u8 = undefined;
var data: [1][]u8 = .{&scratch};
const n = r.readVec(&data) catch return "";
if (n == 0) return "";
```

`std.Io.Reader.readVec` is a thin forward to the reader's vtable, and a vtable
is free to satisfy a read by filling the reader's *own* buffer and reporting
zero bytes written into the caller's slices. `std.Io.Reader.defaultReadVec`
does exactly that whenever the caller's first slice is smaller than the
reader's remaining buffer capacity, and it is explicit in the doc comment on
`readVec`: "The number of bytes read, including zero, does not indicate end of
stream."

TLS never takes the other branch. `std.crypto.tls.Client` installs its own
vtable whose `readVec` discards `data` outright --

```
fn readVec(r: *Reader, data: [][]u8) Reader.Error!usize {
    // This function writes exclusively to the buffer.
    _ = data;
```

-- decrypts the record into `r.buffer`, and returns 0 (`.application_data =>
{ r.end += cleartext.len; return 0; }`). So on a TLS connection every
`read()` returns 0 with the peer's frame sitting decrypted in the buffer, and
`if (n == 0) return ""` reports that as end of stream. The next call decrypts
the next record on top of it and reports nothing again.

Two things follow from this that the earlier spec got wrong:

- `LumenSocket.read()` is not a template that transfers. It is correct where
  it is because a plaintext `Io.net.Stream.Reader` does write into the
  caller's slices. Copying its body onto a reader that may be a TLS reader
  copies an assumption that does not hold there.
- Spec 495 recorded a manual round trip against a public `wss://` echo
  endpoint as passing. It cannot have: the mechanism above is unconditional
  for TLS. That verification is redone here against a real endpoint, with the
  stock v0.7.4 binary run side by side as the control.

`readLine()` is unaffected and always was: `takeDelimiterInclusive` reaches
the connection through `fillMore()`, which is buffer-oriented and therefore
correct for either vtable shape. That is why the same stream can deliver
bytes through `readLine()` (truncated and trimmed, per spec 495) and nothing
at all through `read()`.

## Scope

In scope:

- `LumenHttpStream.read()` in `src/lumen_runtime_net.zig` -- read through the
  reader's buffer rather than through `readVec`'s slice contract.

Out of scope:

- `LumenSocket.read()`. It is on a plaintext stream reader, where `readVec`
  is correct, and it is the read path every existing `net.connect` caller
  uses. Not touched.
- `readLine()`, `write()`, `close()`, and the exhaustion/guard rules, all
  unchanged from specs 494 and 495.
- The `readVec` contract itself. A vtable that fills the reader's buffer and
  returns 0 is documented behaviour, not a bug in `std`.

## Design

```
fn read(self: *LumenHttpStream) []const u8 {
    if (self.done_) return "";
    const r = self.body orelse { self.done_ = true; return ""; };
    if (r.bufferedLen() == 0) {
        r.fillMore() catch { self.done_ = true; self.__release(); return ""; };
    }
    const avail = r.buffered();
    if (avail.len == 0) return "";
    const out = __sa().dupe(u8, avail) catch "";
    r.toss(avail.len);
    return out;
}
```

`fillMore()` is the primitive that means "do exactly one underlying read,
into the buffer". It is what `readLine()`'s delimiter scan already reaches
through, and it is right for either vtable shape -- the TLS reader decrypts a
record into the buffer, the plaintext reader fills the buffer, and neither
depends on a slice the caller passed. `buffered()`/`toss()` then hand out
exactly what arrived, with no delimiter scan and no trimming, which is what
spec 495 asked for.

Reading the buffer *before* filling it is not just an optimisation. The head
parse leaves whatever arrived alongside the `101` still buffered
(`http.Reader.receiveHead` tosses only the head bytes), so for a server that
speaks first -- a relay pushing a frame the moment the socket is up -- those
bytes are the whole first message. The old code never looked at them.

Guards are unchanged: `done_` first, then `self.body`, and an error from
`fillMore()` (end of stream, `close_notify`, or a read failure) ends the
stream through `__release()` exactly as `readLine()` does.

`fillMore()` returning with nothing added is documented as *not* an end of
stream, and this returns `""` for it -- the same `""` a caller already has to
handle for a zero-length read, and the same convention `LumenSocket.read()`
uses. A caller polls; it does not treat one empty read as a closed peer.

## Success Criteria

1. Against a real TLS `wss://` endpoint, a frame the peer sends unprompted
   after the upgrade is delivered by `read()`. The stock v0.7.4 binary
   returns 0 bytes for the identical program; the fixed one returns the
   frame.
2. A masked frame written with `write()`, payload containing embedded `\r`
   and `\n`, comes back through `read()` byte for byte.
3. `read()` after `close()` returns `""` without crashing.
4. `read()` on a plain (non-101) response still returns body bytes.
5. `zig build test` passes; `zig build conformance` matches the pre-change
   baseline.

## Notes

Verified against `wss://echo.websocket.org`, which completes a real RFC 6455
upgrade over real TLS and speaks first, so criterion 1 needs no write at all
to exercise the read path. Both binaries ran the same source file:

```
=== stock v0.7.4 ===          === fixed ===
status=101                    status=101
accept=s3pPLMBiTxaQ9kYGz...   accept=s3pPLMBiTxaQ9kYGz...
read1 len=0                   read1 len=34
```

(`accept` is the RFC 6455 worked example's own value for the key the program
sends, which is how the handshake half is known to be sound in both.)

The round trip, on the fixed binary: greeting 34 bytes, then a masked
`hi\r\nthere` frame written and echoed back as 11 wire bytes whose payload is
the 9 original bytes with both the `\r` and the `\n` intact; `read()` after
`close()` is `""`; a plain `https://example.com/` `GET` reads its 559-byte
body through the same method.

Not added as a conformance case, for the reason spec 495 gave: it needs
network access to a real TLS endpoint, which conformance runs do not have.
The gap that leaves is exactly how a broken `read()` shipped in v0.7.4 with a
passing suite, and it is worth closing eventually with a local TLS fixture --
a loopback listener with a generated certificate would do it, and would cost
a certificate fixture in the repo. Out of scope here.

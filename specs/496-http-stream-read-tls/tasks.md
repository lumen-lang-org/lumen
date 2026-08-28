# Tasks: HttpStream.read over TLS

## Investigation

- [x] Reproduce against a real TLS endpoint before changing anything:
      stock v0.7.4, `wss://echo.websocket.org`, server speaks first,
      `status() == 101` and `read()` returns 0 bytes.
- [x] Read the path rather than guess at it: `Response.reader()` ->
      `http.Reader.bodyReader()`, which for `.none` encoding with no
      `Content-Length` -- a `101`'s exact shape -- returns `reader.in`, the
      connection reader. Correct, and not where the bytes are lost.
- [x] `Connection.reader()` returns `&tls.client.reader` for a TLS
      connection, so `reader.in` is `std.crypto.tls.Client`'s reader.
- [x] `std.crypto.tls.Client`'s reader vtable: `readVec` discards `data`
      ("This function writes exclusively to the buffer"), decrypts into
      `r.buffer`, and returns 0 for `.application_data`. That is the loss:
      `read()` reads 0 as end of stream.
- [x] Confirm `std.Io.Reader.readVec`'s own doc comment allows this --
      "The number of bytes read, including zero, does not indicate end of
      stream" -- so the contract was misread, not violated.
- [x] Confirm why `readLine()` is unaffected: it goes through `fillMore()`,
      which is buffer-oriented and correct for either vtable shape.
- [x] Confirm `LumenSocket.read()` stays correct where it is: a plaintext
      `Io.net.Stream.Reader` does write into the caller's slices.

## Implementation

- [x] `src/lumen_runtime_net.zig`: `LumenHttpStream.read()` reads through
      `bufferedLen()`/`fillMore()`/`buffered()`/`toss()` instead of
      `readVec`, checking already-buffered bytes first so anything that
      arrived alongside the `101` head is not dropped.
- [x] Comment records why `readVec` is wrong here and right in
      `LumenSocket.read()`, so the next reader does not re-copy it.
- [x] `docs/CODEMAP.md` regenerated (`sh tools/codemap.sh`).

## Verification

- [x] `zig build` passes.
- [x] `zig build test` passes.
- [x] `zig build conformance` matches the pre-change baseline.
- [x] Same-source A/B against `wss://echo.websocket.org`: stock v0.7.4
      `read1 len=0`, fixed `read1 len=34`. Handshake identical in both
      (`status=101`, `Sec-WebSocket-Accept` equal to RFC 6455's worked
      example for the key sent), so the difference is the read path alone.
- [x] Round trip on the fixed binary: masked `hi\r\nthere` frame written
      with `write()`, echoed back as 11 wire bytes, payload byte for byte
      including the embedded `\r` and `\n`.
- [x] `read()` after `close()` returns `""`, no crash.
- [x] `read()` on a plain `200` response returns its body (559 bytes from
      `https://example.com/`).

## Follow-up (not this slice)

- [ ] A local TLS fixture (loopback listener, generated certificate) would
      let the WebSocket-over-TLS round trip run in `conformance`. Without
      one, no suite in this repo exercises `read()` over TLS, which is how
      v0.7.4 shipped green with this defect.

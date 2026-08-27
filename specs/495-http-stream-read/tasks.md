# Tasks: HttpStream.read

## Investigation

- [x] Confirm `self.body` is the same raw connection reader `readLine()`
      already reaches post-101 -- true by construction, `read()` reads from
      the same field.
- [x] Confirm `LumenSocket.read()` as the style/semantics template: guard
      nullable state, one `readVec` call, `""` on error/EOF, no delimiter,
      no trimming.
- [x] Confirm spec 494's `write()` as the template for how a method gets
      threaded through checker + runtime for this type: a
      `lumen_check_methods.zig` case in `httpStreamMethod` plus a
      `lumen_runtime_net.zig` method on `LumenHttpStream`, no separate
      emit-side wiring (the generic `container_type` emit path already
      lowers `<recv>.<name>(<args>)` to the runtime struct method).

## Implementation

- [x] `src/lumen_runtime_net.zig`: `LumenHttpStream.read(): []const u8` --
      guard `self.done_`/`self.body`, one `readVec` into a 64KB scratch
      buffer, `""` on error or zero-length read, otherwise a fresh copy of
      what arrived.
- [x] `src/lumen_check_methods.zig`: `read` case in `httpStreamMethod`, 0
      args, returns `.string` -- same shape as `readLine`'s case.
- [x] Doc comment above `httpStreamMethod` updated to list `read`.
- [x] `docs/CODEMAP.md` regenerated (`sh tools/codemap.sh`).

## Verification

- [x] `zig build` passes.
- [x] `zig build test` passes.
- [x] `zig build conformance`: failure count compared against baseline
      `main` (pre-change), not zero -- pre-existing failures unrelated to
      this change are expected and unaffected.
- [x] Manual round trip against `wss://ws.postman-echo.com/raw` (real TLS,
      real RFC 6455 handshake, public echo endpoint): `status() == 101`,
      `Sec-WebSocket-Accept` matches the RFC 6455 worked example, a masked
      frame with a payload containing embedded `\r`/`\n` bytes written via
      `write()` comes back through `read()` byte-for-byte. The same
      payload through `readLine()` truncates at the first embedded `\n`,
      confirming the exact defect this spec fixes. `read()` after `close()`
      returns `""` without crashing. `read()` on a plain (non-101) response
      and on a connection that never succeeded both behave without
      crashing.

## Follow-up (not this slice)

- [ ] A full WebSocket frame codec (mask/unmask, opcode handling, ping/pong,
      extended-length fields) on top of `write()`/`read()` is application
      code, not this repo's -- same boundary spec 494 drew.

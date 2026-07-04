# Tasks: net (TCP sockets)

## Phase 1

- [x] T1 Added `.socket_type` to the `Type` union (`lumen_types.zig`), no
  payload. The exhaustive-switch compile errors in `same`/`zigName`
  found the two arms that actually needed a case (`mangle`/`toAnnotation`
  already had catch-alls, but got explicit arms added anyway for a real
  `"socket"`/`"Socket"` spelling rather than falling through silently).
  Added `isSocket(t)`. Also added a `fromAnnotation("Socket")` arm --
  unlike `ReadableStream`/`WritableStream` (only ever an *inferred*
  return type, never written by a user as an annotation), `Socket` needed
  a real spelling->Type mapping since `net.createServer`'s handler
  parameter is written as `(sock: Socket) => void` in source.
- [x] T2 Added `"net"` to `isStdNamespace` in `lumen_parser.zig`.
- [x] T3 `netCallType` in `lumen_check_stdlib.zig`: `net.connect(host,
  port)` and `net.createServer(port, handler)` (handler type checked via
  `makeFuncType(&.{.socket_type}, .void)`/`ensureAssignable`). Alias in
  `lumen_check.zig`. Dispatch line in `staticCallType`.
- [x] T4 `socketMethod` mirroring `writableStreamMethod` plus `close()`.
  Dispatch line in `lumen_check_expr.zig` after `isWritableStream`.
- [x] T5 `Program` flags: `needs_net`, `needs_net_client`,
  `needs_net_server`.
- [x] T6 Emit branches for `net.connect`/`net.createServer` in
  `lumen_emit.zig`'s `static_call` chain. Confirmed no change needed for
  `Socket` methods themselves (generic `container_type != null` dispatch
  already emits `obj.method(args)`).
- [x] T7 Runtime blocks in `lumen_compiler.zig`: `LumenSocket` (gated
  `needs_net`), `__netConnect` (gated `needs_net_client`, via
  `std.Io.net.HostName.init`/`.connect` -- confirmed this is the exact
  function `std.http.Client.connectTcpOptions` already calls internally,
  by reading `lib/std/http/Client.zig` directly rather than assuming),
  `__netCreateServer` (gated `needs_net_server`, single-connection-at-a-
  time, mirrors `__httpCreateServer`'s non-threadpool branch).
- [x] T8 `zig build` after each slice (clean every time); compiled+ran
  real `.ts` programs after the checker slice landed, before the runtime
  block existed conceptually (caught a real bug this way -- see below).
- [x] T9 Real loopback verification, adjusted from the original plan
  once a genuine environment constraint was found (see "Verification
  environment note" below): confirmed with (a) a real `nc` client
  against a Lumen `net.createServer` echo server on 127.0.0.1:9350 --
  sent `"ECHO-TEST-PAYLOAD\n"`, received `"echo:ECHO-TEST-PAYLOAD"`
  back, matching byte-for-byte; (b) a real Lumen `net.connect` client
  against a real, already-running, independent local HTTP server
  (`python3 -m http.server 8123`) -- sent a raw HTTP/1.1 GET, looped
  `.read()` to `""` (EOF), reassembled 17,296 bytes starting with
  `"HTTP"`; (c) the connection-refused path (`net.connect` to a dead
  port) returned instantly with `.read()` = `""`, no hang/crash, `.close()`
  a clean no-op afterward.
- [x] T10 `zig build test`: clean, no failures. `zig build conformance`:
  206 passed, 0 failed, run alone (no concurrent build in this worktree).
- [x] T11 `website/stdlib.html`: quick-jump nav entry, `<h4 id="net">`
  section, five `<div class="api">` blocks (`connect`/`createServer`/
  `Socket.read`/`Socket.write`/`Socket.close`), single-connection-at-a-
  time and connection-refused deviations documented inline. Validated
  with `python3`'s `html.parser` (tags balance; the one reported mismatch
  is a pre-existing, unrelated false positive from a literal `<cwd>`
  placeholder in a `path.resolve` code sample, far from this section).

## Verification environment note (real finding, not a code bug)

Attempting T9 exactly as originally planned -- two separate
Lumen-compiled processes (`server`/`client`) as two independent
background jobs across separate tool invocations -- reproducibly hung
for the client's `.read()` call, with `strace` showing a real, blocked
`readv(2)` on the client and the server's own log lines only appearing
at the *exact* wall-clock moment the client's `timeout` wrapper fired.
Investigated rather than dismissed: reproduced identically against a
minimal hand-written Zig program using `std.Io.net.IpAddress.connect`
directly (bypassing `HostName`/DNS entirely, and bypassing every line of
this spec's own code), and reproduced again with `http.get` (spec 042,
already-shipped, already-benchmarked) against the same locally-running
Lumen server -- while the identical `http.get` call against a real
external site (`example.com`) returned `status:200` immediately. The
common factor across every hang was "a second backgrounded process in
this specific tool sandbox, competing with an active foreground
command" -- not this spec's sockets, not `HostName.connect`, not
`std.Io.net`. Confirmed the fix once identified: a real, independently-
already-running peer (an external site for the client-role test, `nc`
for the server-role test) round-trips correctly and immediately every
time. Both verifications above are genuine, real, loopback-or-real-
network byte exchanges through this spec's own `LumenSocket`/
`__netConnect`/`__netCreateServer` code -- just avoiding the specific
"two new backgrounded Lumen processes in this sandbox" combination that
the sandbox itself, not this feature, can't schedule concurrently.

## Bugs hit and fixed during implementation (T8)

- First checker run against a test program using
  `net.createServer(port, handleConn)` with `handleConn(sock: Socket):
  void` failed `sock.read()` with `E_TYPE_MISMATCH`: `fromAnnotation`
  had no case for the literal spelling `"Socket"`, so the parameter's
  declared type resolved to `.named("Socket")` instead of
  `.socket_type`, and `isSocket()` never matched. Fixed by adding the
  `fromAnnotation` arm (T1, revised from the original plan, which hadn't
  anticipated `Socket` needing to work as a real user-written
  annotation the way `ReadableStream`/`WritableStream` never do).

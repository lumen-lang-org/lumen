# Spec 054: net (TCP sockets)

## Goal

A `net` namespace exposing raw TCP: `net.connect(host, port)` for a client
socket and `net.createServer(port, handler)` for a server that hands each
accepted connection to a callback -- the primitive `http`'s own server
(spec 042/049) and client (`std.http.Client.fetch`) are already built on,
but not previously exposed to Lumen source directly. Every other network
capability this session shipped (`http.request`, `http.createServer`) went
through HTTP framing; this spec is the one below that: raw bytes over a
socket, no protocol assumed.

## What already exists and what's new

`http.createServer`'s runtime block (`__httpCreateServer` in
`lumen_compiler.zig`, gated on `needs_http_server`) already does
`std.Io.net.IpAddress.parse("0.0.0.0", port).listen(io, .{.reuse_address =
true})`, `server.accept(io)`, and `stream.reader(io, buf)`/
`stream.writer(io, buf)` -- confirmed by reading it directly before writing
this spec, and used verbatim as the accept-loop template below. What's new:

- **The client side.** Nothing in the codebase calls
  `std.Io.net.IpAddress.connect`/`std.Io.net.HostName.connect` directly yet
  -- checked `/opt/zig`'s actual toolchain path (`zig env`) and read
  `lib/std/Io/net.zig` and `lib/std/Io/net/HostName.zig` source directly
  rather than assuming a Node-like `net.connect` shape exists ready-made.
  Two connect entry points exist at this layer:
  - `IpAddress.connect(address, io, options) ConnectError!Stream` -- takes
    an already-parsed literal IP address, no DNS.
  - `HostName.connect(host_name, io, port, options) ConnectError!Stream`
    -- takes a validated `HostName` (`HostName.init(bytes)`, RFC 1123
    validation only, no network call) and does real DNS resolution
    internally via `io.async`/`io.vtable.netLookup`, trying every resolved
    address until one connects. Confirmed this exact function is the one
    `std.http.Client.connectTcpOptions` already calls internally
    (`lib/std/http/Client.zig`, `connectTcpOptions`: `host.connect(io,
    port, .{.mode = .stream})`) -- meaning hostname resolution through
    `io.async` on this codebase's `__io` (`__init.io` from
    `std.process.Init`, threaded through every async/threadpool feature
    already shipped) is already proven to work in this exact binary, not a
    new, unverified code path. `net.connect` uses `HostName.connect`
    (accepts both real hostnames and literal IPs -- `HostName.validate`
    treats `"127.0.0.1"` as a valid hostname too, confirmed against the
    doc-tests in `HostName.zig` directly) rather than the narrower
    `IpAddress.connect`, so `net.connect("example.com", 80)` and
    `net.connect("127.0.0.1", 9301)` both work through one code path.
- **A dedicated `Socket` type.** Following spec 046's exact
  `ReadableStream`/`WritableStream` playbook: a bare `Type` variant
  (`.socket_type`, no payload -- every chunk is `string`, matching every
  other body/chunk this stdlib represents), `isSocket()`, a `socketMethod`
  dispatch mirroring `readableStreamMethod`/`writableStreamMethod`
  (`mc.container_type = obj_type` sentinel so the existing generic
  method-call emit path handles codegen with zero `lumen_emit.zig` changes
  for the methods themselves), and a `LumenSocket` runtime struct wrapping
  `std.Io.net.Stream`'s reader/writer the same way `LumenReadableStream`/
  `LumenWritableStream` wrap a file's.

## API (v1 scope)

| Function | Type | Notes |
| --- | --- | --- |
| `net.connect(host, port)` | `(string, int) -> Socket` | blocking connect; a failed connect (refused, unknown host, timeout) degrades to a `Socket` whose `.read()` always returns `""` and `.write()` is a no-op -- the same "fallback, don't crash" convention `LumenReadableStream`'s missing-file case already established, not a thrown error |
| `net.createServer(port, handler)` | `(int, (Socket) -> void) -> void` | accepts connections concurrently (spec 490): each accepted connection's `handler(socket)` call runs on its own worker thread from a dedicated `xev.ThreadPool`, and closes the socket when the handler returns (whether or not the handler itself already called `.close()` -- `LumenSocket.close()` is idempotent, see below) |

| Method | Type | Notes |
| --- | --- | --- |
| `Socket.read()` | `() -> string` | next chunk (bounded by a fixed 64KB internal buffer, matching `ReadableStream.read()`'s exact convention); `""` at EOF/closed/never-connected -- same "empty chunk and end-of-stream are indistinguishable" simplification spec 046 already documented and accepted for streams |
| `Socket.write(chunk)` | `string -> void` | writes and flushes immediately (a socket makes no buffering promise the way a one-shot file write does); no-op on a closed/never-connected socket |
| `Socket.close()` | `() -> void` | closes the underlying stream; safe to call more than once or on a never-connected socket |

## Design notes

- **Handler receives a `Socket`, not a request/response record pair.**
  `http.createServer`'s handler is `(HttpRequest) -> HttpResponse` because
  HTTP is a call-and-return protocol Lumen already parses framing for. TCP
  has no such framing -- a handler needs to read and write in whatever
  order/shape its own protocol demands (an echo server, a line protocol, a
  binary protocol), so the natural shape here is "hand over the socket,
  let the handler drive it," matching how `net.Socket`-style APIs work in
  every other server-side language. Checked via `makeFuncType`/
  `ensureAssignable` the same way `http.createServer`'s handler type is
  checked (`self.makeFuncType(&.{.socket_type}, .void)`).
- **Concurrent, via the same `xev.ThreadPool` treatment `http.createServer`
  got in spec 049 (spec 490, fixes lumen#11).** Originally shipped single
  connection at a time (a slow or long-lived handler blocked every other
  connection from being accepted at all, not merely delayed), documented
  below as deliberately deferred. Filed upstream as
  [lumen#11](https://github.com/lumen-lang-org/lumen/issues/11) once a real
  caller (a relay serving concurrent long-lived WebSocket connections)
  needed it; fixed in spec 490 exactly the way this note predicted -- the
  accept loop now hands each accepted `Stream` + handler to a
  `ThreadPool.Task` instead of calling the handler inline.
- **`LumenSocket.close()` is idempotent (`closed: bool` flag), and the
  accept loop always calls it after the handler returns.** Unlike
  `WritableStream.close()` (caller-driven, called once, matching a
  "flush this file and I'm done with it" flow), a socket handler forgetting
  to close leaks an fd for the lifetime of a long-running server -- so the
  server closes on the handler's behalf regardless, and closing twice
  (once by a handler that already closed it, once by the server) is a
  guarded no-op rather than a double-close error, the same shape
  `LumenReadableStream.close()`'s `if (self.file) |f|` guard already uses.
- **`.write()` flushes on every call, unlike `WritableStream.write()`**
  (which defers flushing to `.close()`). A one-shot file write has an
  obvious "I'm done, flush now" moment (`.close()`); a long-lived socket
  conversation (a client sending one line, waiting for the server's
  reply) does not -- buffering a write until some later, unspecified
  `.close()` would mean the peer never sees it in time. Matches
  `http.createServer`'s own per-response `w.flush()` call in its existing
  runtime block.
- **No TLS.** Plaintext TCP only, matching Node's `net` module itself
  (`tls.connect`/`tls.createServer` are Node's separate, TLS-specific
  module) -- not a Lumen-specific gap.

## Not planned (this pass)

| Item | Why |
| --- | --- |
| UDP (`net.dgram`/`dgram` module equivalent) | a different `Socket.Mode` (`.dgram` vs `.stream`) and connectionless send/receive API shape (`Socket.send`/`receive` in `std.Io.net`, distinct from `Stream`'s reader/writer) -- a separate primitive, not an extension of this one |
| TLS (`tls.connect`/`tls.createServer`) | Node itself splits this into a separate `tls` module; `std.crypto.tls` integration is a real, separate feature |
| Socket options (`setNoDelay`, `setKeepAlive`, `setTimeout`) | not exercised by the v1 verification (a real loopback round-trip); straightforward additions later, each one `io.vtable`/`std.posix.setsockopt` plumbing behind a new `Socket` method |
| Connection timeouts on `net.connect` | `HostName.connect`'s `ConnectOptions.timeout` field (`Io.Timeout`) already exists at the Zig layer and could be threaded through a third optional argument later; left out to keep the v1 signature exactly `(host, port)` |

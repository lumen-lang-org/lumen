//! Runtime prelude codegen for the network surface: the `http` client
//! module, the concurrent `http.createServer` runtime, `net` sockets,
//! HTTP constants, and JSON.
//!
//! Extracted from `lumen_compiler.zig` purely by size: each `emit*` function
//! appends the same gated runtime-prelude Zig source blocks it always did,
//! in the same order, driven by the `program.needs_*` flags the checker set.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const CompileOptions = @import("lumen_emit.zig").CompileOptions;
const CompileError = @import("lumen_diag.zig").CompileError;

pub fn emitNetRuntime(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), program: *const ast.Program, options: CompileOptions) CompileError!void {
    const needs_http_threadpool = program.needs_http_server and !options.wasm;
    if (program.needs_http_module) {
        // http.request/get (spec 042): one-shot client request via
        // std.http.Client.fetch, with a real method/payload/response body
        // -- a genuine capability upgrade over the old status-only
        // httpGet global. Response headers aren't surfaced: fetch's
        // convenience wrapper only exposes status, reading headers needs
        // the lower-level request/response flow underneath it.
        try out.appendSlice(arena,
            \\pub const __LumenHttpResponse = struct { status: i32, body: []const u8, ok: bool, headers: *LumenMap([]const u8, []const u8) };
            \\fn __httpRequest(io: std.Io, alloc: std.mem.Allocator, url: []const u8, method: []const u8, body: []const u8, headers: *LumenMap([]const u8, []const u8)) __LumenHttpResponse {
            \\    var client: std.http.Client = .{ .allocator = alloc, .io = io };
            \\    defer client.deinit();
            \\    // Loading the system CA bundle means reading and parsing a real
            \\    // certificate file from disk -- skip it entirely for plain http://
            \\    // requests, which never need it, rather than paying that cost on
            \\    // every single call regardless of scheme.
            \\    const resp_headers = LumenMap([]const u8, []const u8).__init();
            \\    if (std.mem.startsWith(u8, url, "https://")) {
            \\        client.ca_bundle.rescan(alloc, io, std.Io.Clock.now(.real, io)) catch return .{ .status = -1, .body = "", .ok = false, .headers = resp_headers };
            \\    }
            \\    const extra_headers = alloc.alloc(std.http.Header, headers.keys_.items.len) catch unreachable;
            \\    for (headers.keys_.items, headers.values_.items, 0..) |k, v, i| extra_headers[i] = .{ .name = k, .value = v };
            \\    var resp_writer: std.Io.Writer.Allocating = .init(alloc);
            \\    const http_method = std.meta.stringToEnum(std.http.Method, method) orelse .GET;
            \\    const payload: ?[]const u8 = if (body.len > 0) body else null;
            \\    const res = client.fetch(.{
            \\        .location = .{ .url = url },
            \\        .method = http_method,
            \\        .payload = payload,
            \\        .extra_headers = extra_headers,
            \\        .response_writer = &resp_writer.writer,
            \\    }) catch return .{ .status = -1, .body = "", .ok = false, .headers = resp_headers };
            \\    const status_code: i32 = @intFromEnum(res.status);
            \\    // Response headers deliberately not populated yet: fetch()'s
            \\    // convenience wrapper only surfaces status. Reading them for real
            \\    // needs the lower-level client.request()/receiveHead()/
            \\    // iterateHeaders() flow underneath it -- confirmed reachable by
            \\    // reading the source, but restructuring this already-working,
            \\    // already-benchmarked call risked regressing it under time
            \\    // pressure, so it's a deliberate, documented follow-up rather
            \\    // than a rushed rewrite (spec 045).
            \\    return .{ .status = status_code, .body = resp_writer.written(), .ok = status_code >= 200 and status_code < 300, .headers = resp_headers };
            \\}
            \\
        );
    }
    if (program.needs_http_stream) {
        // http.stream (spec 452): a live read handle over a response in
        // progress. Uses the lower-level open-request/send/receive-head flow
        // beneath fetch — the flow the buffered client's own comment (above)
        // maps out — because the whole point is to hand back a handle before
        // the body exists. The response body reader decodes chunked
        // transfer-encoding transparently (confirmed against std's
        // http.Reader.bodyReader: the `.chunked` arm installs a
        // chunk-decoding stream), so readLine() yields protocol lines, never
        // chunk frames. The handle owns the client (and with it the
        // connection + TLS state) for the stream's lifetime; close() and
        // natural exhaustion both release it. Any open/connect/TLS failure
        // degrades to a handle with status -1 and done() true — the same
        // "fallback, don't crash" convention as the buffered client's
        // status -1.
        //
        // Compressed content-encodings are declined (Accept-Encoding:
        // identity): a token stream must arrive as wire bytes, and SSE
        // providers all honor identity.
        //
        // v1 limits (documented, accepted, same as ChildProcess.readLine):
        // a single line longer than the 64KB transfer buffer ends the
        // stream; the handle is single-consumer.
        try out.appendSlice(arena,
            \\pub const LumenHttpStream = struct {
            \\    client: ?*std.http.Client = null,
            \\    req: ?*std.http.Client.Request = null,
            \\    body: ?*std.Io.Reader = null,
            \\    status_: i32 = -1,
            \\    hdr_names: []const []const u8 = &.{},
            \\    hdr_values: []const []const u8 = &.{},
            \\    done_: bool = true,
            \\    // The stream's own buffers. A service opens one stream per
            \\    // request, so these must come from a freeable allocator and be
            \\    // released with the connection -- taking them from the program
            \\    // arena (never reset) would leak ~73KB per call, which is
            \\    // unbounded growth on exactly the long-running proxy this
            \\    // feature exists for.
            \\    tbuf_: []u8 = &.{},
            \\    rbuf_: []u8 = &.{},
            \\    xhdr_: []std.http.Header = &.{},
            \\    fn __fail() *LumenHttpStream {
            \\        const p = __sa().create(LumenHttpStream) catch unreachable;
            \\        p.* = .{};
            \\        return p;
            \\    }
            \\    fn status(self: *LumenHttpStream) i32 {
            \\        return self.status_;
            \\    }
            \\    fn header(self: *LumenHttpStream, name: []const u8) []const u8 {
            \\        for (self.hdr_names, self.hdr_values) |n, v| {
            \\            if (std.ascii.eqlIgnoreCase(n, name)) return v;
            \\        }
            \\        return "";
            \\    }
            \\    fn done(self: *LumenHttpStream) bool {
            \\        return self.done_;
            \\    }
            \\    fn readLine(self: *LumenHttpStream) []const u8 {
            \\        if (self.done_) return "";
            \\        const r = self.body orelse {
            \\            self.done_ = true;
            \\            return "";
            \\        };
            \\        const raw = r.takeDelimiterInclusive('\n') catch |e| {
            \\            if (e == error.EndOfStream) {
            \\                // A final line without a terminator: hand it out now;
            \\                // the next call sees a clean end of stream.
            \\                const left = r.buffered();
            \\                if (left.len > 0) {
            \\                    const line = __sa().dupe(u8, std.mem.trimEnd(u8, left, "\r")) catch "";
            \\                    r.toss(left.len);
            \\                    return line;
            \\                }
            \\            }
            \\            self.done_ = true;
            \\            self.__release();
            \\            return "";
            \\        };
            \\        return __sa().dupe(u8, std.mem.trimEnd(u8, raw, "\r\n")) catch "";
            \\    }
            \\    fn close(self: *LumenHttpStream) void {
            \\        self.done_ = true;
            \\        self.__release();
            \\    }
            \\    // Idempotent: close() then exhaustion (or a double close) must
            \\    // not double-free. Every field is cleared as it is released.
            \\    fn __release(self: *LumenHttpStream) void {
            \\        self.body = null;
            \\        // Request.deinit marks a mid-body connection as closing;
            \\        // Client.deinit then tears down every connection it still
            \\        // owns, including TLS state. The buffers are freed after
            \\        // deinit, which still reads through them.
            \\        if (self.req) |rq| {
            \\            rq.deinit();
            \\            std.heap.page_allocator.destroy(rq);
            \\            self.req = null;
            \\        }
            \\        if (self.client) |c| {
            \\            c.deinit();
            \\            std.heap.page_allocator.destroy(c);
            \\            self.client = null;
            \\        }
            \\        if (self.tbuf_.len > 0) {
            \\            std.heap.page_allocator.free(self.tbuf_);
            \\            self.tbuf_ = &.{};
            \\        }
            \\        if (self.rbuf_.len > 0) {
            \\            std.heap.page_allocator.free(self.rbuf_);
            \\            self.rbuf_ = &.{};
            \\        }
            \\        if (self.xhdr_.len > 0) {
            \\            std.heap.page_allocator.free(self.xhdr_);
            \\            self.xhdr_ = &.{};
            \\        }
            \\    }
            \\};
            \\fn __httpStreamOpen(io: std.Io, alloc: std.mem.Allocator, url: []const u8, method: []const u8, body: []const u8, headers: *LumenMap([]const u8, []const u8)) anyerror!*LumenHttpStream {
            \\    // Everything the stream owns comes from a freeable allocator,
            \\    // not the program arena: the handle is released by close() or
            \\    // by reaching the end of the body, and a service opens one per
            \\    // request.
            \\    const pa = std.heap.page_allocator;
            \\    const uri = try std.Uri.parse(url);
            \\    const client = try pa.create(std.http.Client);
            \\    errdefer pa.destroy(client);
            \\    client.* = .{ .allocator = alloc, .io = io };
            \\    errdefer client.deinit();
            \\    const extra_headers = try pa.alloc(std.http.Header, headers.keys_.items.len);
            \\    errdefer pa.free(extra_headers);
            \\    for (headers.keys_.items, headers.values_.items, 0..) |k, v, i| extra_headers[i] = .{ .name = k, .value = v };
            \\    const http_method = std.meta.stringToEnum(std.http.Method, method) orelse .GET;
            \\    const req = try pa.create(std.http.Client.Request);
            \\    errdefer pa.destroy(req);
            \\    req.* = try client.request(http_method, uri, .{
            \\        .extra_headers = extra_headers,
            \\        .headers = .{ .accept_encoding = .{ .override = "identity" } },
            \\        .redirect_behavior = if (body.len == 0) @enumFromInt(3) else .unhandled,
            \\    });
            \\    errdefer req.deinit();
            \\    if (body.len > 0) {
            \\        req.transfer_encoding = .{ .content_length = body.len };
            \\        var bw = try req.sendBodyUnflushed(&.{});
            \\        try bw.writer.writeAll(body);
            \\        try bw.end();
            \\        try req.connection.?.flush();
            \\    } else {
            \\        try req.sendBodiless();
            \\    }
            \\    const redirect_buffer = try pa.alloc(u8, 8 * 1024);
            \\    errdefer pa.free(redirect_buffer);
            \\    var response = try req.receiveHead(redirect_buffer);
            \\    const tbuf = try pa.alloc(u8, 65536);
            \\    errdefer pa.free(tbuf);
            \\    // The handle itself stays on the arena: user code holds it and
            \\    // may still ask for status() or header() after close(), so it
            \\    // outlives the connection by design. It is ~80 bytes plus the
            \\    // copied header text, not the 73KB of buffers above.
            \\    const p = __sa().create(LumenHttpStream) catch unreachable;
            \\    p.* = .{
            \\        .client = client,
            \\        .req = req,
            \\        .status_ = @intFromEnum(response.head.status),
            \\        .done_ = false,
            \\        .tbuf_ = tbuf,
            \\        .rbuf_ = redirect_buffer,
            \\        .xhdr_ = extra_headers,
            \\    };
            \\    // Copy the header names/values out NOW: initializing the body
            \\    // reader below invalidates the head's backing memory.
            \\    var names: std.ArrayListUnmanaged([]const u8) = .empty;
            \\    var values: std.ArrayListUnmanaged([]const u8) = .empty;
            \\    var hit = std.http.HeaderIterator.init(response.head.bytes);
            \\    while (hit.next()) |h| {
            \\        names.append(__sa(), __sa().dupe(u8, h.name) catch unreachable) catch unreachable;
            \\        values.append(__sa(), __sa().dupe(u8, h.value) catch unreachable) catch unreachable;
            \\    }
            \\    p.hdr_names = names.items;
            \\    p.hdr_values = values.items;
            \\    p.body = response.reader(tbuf);
            \\    return p;
            \\}
            \\fn __httpStream(io: std.Io, alloc: std.mem.Allocator, url: []const u8, method: []const u8, body: []const u8, headers: *LumenMap([]const u8, []const u8)) *LumenHttpStream {
            \\    return __httpStreamOpen(io, alloc, url, method, body, headers) catch LumenHttpStream.__fail();
            \\}
            \\
        );
    }
    if (program.needs_http_server_stream) {
        // ResponseWriter (spec 452): the write handle a two-parameter
        // streaming handler receives. Every write() frames one chunk and
        // flushes it to the socket immediately — immediate delivery is
        // the entire point of the streaming form; buffering until end()
        // would rebuild exactly the bug this exists to fix. writeHead()
        // is once-only (later calls are no-ops); a write() or end()
        // before any writeHead() implies writeHead(200, {}).
        try out.appendSlice(arena,
            \\pub const LumenResponseWriter = struct {
            \\    w: *std.Io.Writer,
            \\    keep_alive: bool,
            \\    head_sent: bool = false,
            \\    ended: bool = false,
            \\    fn __head(self: *LumenResponseWriter, status: i32, headers: ?*LumenMap([]const u8, []const u8)) void {
            \\        if (self.head_sent) return;
            \\        self.head_sent = true;
            \\        const conn_header: []const u8 = if (self.keep_alive) "keep-alive" else "close";
            \\        self.w.print("HTTP/1.1 {d} OK\r\nTransfer-Encoding: chunked\r\nConnection: {s}\r\n", .{ status, conn_header }) catch return;
            \\        if (headers) |hm| {
            \\            for (hm.keys_.items, hm.values_.items) |hk, hv| {
            \\                self.w.print("{s}: {s}\r\n", .{ hk, hv }) catch return;
            \\            }
            \\        }
            \\        self.w.writeAll("\r\n") catch return;
            \\        self.w.flush() catch {};
            \\    }
            \\    fn writeHead(self: *LumenResponseWriter, status: i32, headers: *LumenMap([]const u8, []const u8)) void {
            \\        if (self.ended) return;
            \\        self.__head(status, headers);
            \\    }
            \\    fn write(self: *LumenResponseWriter, chunk: []const u8) void {
            \\        if (self.ended) return;
            \\        if (!self.head_sent) self.__head(200, null);
            \\        // A zero-length frame would be the stream terminator on
            \\        // the wire — an empty write is a no-op instead.
            \\        if (chunk.len == 0) return;
            \\        self.w.print("{x}\r\n", .{chunk.len}) catch return;
            \\        self.w.writeAll(chunk) catch return;
            \\        self.w.writeAll("\r\n") catch return;
            \\        self.w.flush() catch {};
            \\    }
            \\    fn end(self: *LumenResponseWriter) void {
            \\        if (self.ended) return;
            \\        if (!self.head_sent) self.__head(200, null);
            \\        self.ended = true;
            \\        self.w.writeAll("0\r\n\r\n") catch return;
            \\        self.w.flush() catch {};
            \\    }
            \\};
            \\
        );
    }
    if (program.needs_http_server) {
        // http.createServer (spec 042 Phase 2, concurrency in spec 049): a
        // real request-inspecting server, superseding the old canned-response
        // serve() global. Real HTTP/1.1 request-line + header parsing
        // (method, path, Content-Length-based body), reusing the exact
        // manual parsing approach the playground's own compile service
        // already proves works.
        //
        // HTTP keep-alive: the reader/writer (and the underlying buffered
        // state) are set up once per accepted connection, then an inner
        // loop reads and answers requests off that same stream until the
        // client either sends `Connection: close` or the connection drops.
        // Benchmarked ~1.3-1.5x slower than Node's http.createServer before
        // this; root cause was closing the connection after every single
        // response (a fresh TCP handshake per request), the same gap this
        // closes.
        //
        // Request headers (spec 459): the header block was already being read
        // to find Content-Length, so surfacing it costs one map insert per
        // line and no second parse. The map is built in the connection arena,
        // not the process-wide one: it is valid for the handler call and no
        // longer, exactly like the method/path/body slices beside it, and a
        // per-request allocation in a process-lifetime arena would grow a
        // server that is meant to run forever.
        try out.appendSlice(arena,
            \\pub const __LumenHttpRequest = struct { method: []const u8, path: []const u8, body: []const u8, headers: *LumenMap([]const u8, []const u8) };
            \\fn __httpReqHeaders(alloc: std.mem.Allocator) ?*LumenMap([]const u8, []const u8) {
            \\    const m = alloc.create(LumenMap([]const u8, []const u8)) catch return null;
            \\    m.* = .{};
            \\    return m;
            \\}
            \\fn __httpReqHeader(m: *LumenMap([]const u8, []const u8), alloc: std.mem.Allocator, name: []const u8, value: []const u8) void {
            \\    // A line with no name, or none of the value a name promises, is
            \\    // dropped rather than stored: a server answers whatever a client
            \\    // sends it, including nonsense. A line with no colon at all never
            \\    // reaches here -- the caller's parse skips it.
            \\    if (name.len == 0 or value.len == 0) return;
            \\    // Both sides are copied out of the read buffer, which the next
            \\    // line read overwrites.
            \\    const lower = alloc.alloc(u8, name.len) catch return;
            \\    for (name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
            \\    const val = alloc.dupe(u8, value) catch return;
            \\    // A header sent twice keeps the last value, which is what setting
            \\    // the same key twice on a Map does.
            \\    for (m.keys_.items, 0..) |k, i| if (std.mem.eql(u8, k, lower)) {
            \\        m.values_.items[i] = val;
            \\        return;
            \\    };
            \\    m.keys_.append(alloc, lower) catch return;
            \\    m.values_.append(alloc, val) catch return;
            \\}
            \\
        );
        if (needs_http_threadpool) {
            // Concurrent serving (spec 049): the accept loop used to handle
            // one connection fully (through keep-alive, to disconnect)
            // before looping back to accept() the next one -- genuinely one
            // connection at a time, no concurrency, documented as a known
            // gap in spec 042's Not-planned table. Fixed here by handing
            // each accepted connection's *entire* handling (the keep-alive
            // inner loop below, unchanged from the single-threaded version)
            // to a worker thread from a dedicated libxev `ThreadPool`
            // (`src/ThreadPool.zig` -- a real, generic, standalone
            // worker-thread pool with no OS-specific or event-loop
            // integration required, already proven inside libxev's own
            // kqueue backend), so `accept()` can immediately loop back for
            // the next connection while earlier ones are still being
            // served. `http.createServer` is `noreturn` and never needs to
            // signal a result back to the main thread, so unlike an
            // async-fs-Promise scenario (spec 047), no `xev.Async`/
            // completion-queue wake-up bridge is needed here -- each worker
            // just handles its connection to completion and returns.
            //
            // Known trade-off, documented rather than silently ignored: the
            // handler now genuinely runs on multiple OS threads
            // concurrently. If a handler mutates shared global state,
            // that's now a real data race -- exactly as it would be in any
            // multi-threaded server in any language. Not addressed here
            // (would need a general-purpose locking primitive Lumen doesn't
            // have yet); documented in website/stdlib.html.
            try out.appendSlice(arena,
                \\var __http_pool: xev.ThreadPool = undefined;
                \\fn __httpCreateServer(io: std.Io, alloc: std.mem.Allocator, port: i32, handler: anytype) noreturn {
                \\    _ = alloc;
                \\    const addr = std.Io.net.IpAddress.parse("0.0.0.0", @intCast(port)) catch std.process.exit(1);
                \\    var server = addr.listen(io, .{ .reuse_address = true }) catch std.process.exit(1);
                \\    // One connection task occupies a worker for the connection's
                \\    // whole keep-alive lifetime, blocked on socket reads between
                \\    // requests. So the pool must be sized for I/O concurrency (how
                \\    // many connections may be in flight), NOT CPU parallelism: the
                \\    // default `max_threads = getCpuCount()` caps concurrent
                \\    // connections at the core count, and every connection beyond
                \\    // that starves in the queue until an active one closes. HTTP
                \\    // serving is I/O-bound (workers mostly wait, not compute), so a
                \\    // large pool is the right shape here (as Node's epoll loop and
                \\    // Go's scheduler are). A modest per-thread stack keeps the
                \\    // virtual-memory cost of many idle workers negligible.
                \\    // Initialized here (not at file scope) because `getCpuCount`
                \\    // and the `@max` below are runtime values, not comptime-known.
                \\    const __http_cpus: u32 = @intCast(std.Thread.getCpuCount() catch 1);
                \\    __http_pool = xev.ThreadPool.init(.{
                \\        .max_threads = @max(4, __http_cpus * 2),
                \\        .stack_size = 512 * 1024,
                \\    });
                \\    const Handler = @TypeOf(handler);
                \\    const Conn = struct {
                \\        task: xev.ThreadPool.Task = .{ .callback = run },
                \\        io: std.Io,
                \\        stream: std.Io.net.Stream,
                \\        handler: Handler,
                \\        fn run(t: *xev.ThreadPool.Task) void {
                \\            const self: *@This() = @fieldParentPtr("task", t);
                \\            defer std.heap.page_allocator.destroy(self);
                \\            const io2 = self.io;
                \\            const stream = self.stream;
                \\            defer stream.close(io2);
                \\            var read_buf: [16 * 1024]u8 = undefined;
                \\            var reader = stream.reader(io2, &read_buf);
                \\            const r = &reader.interface;
                \\            var write_buf: [16 * 1024]u8 = undefined;
                \\            var writer = stream.writer(io2, &write_buf);
                \\            const w = &writer.interface;
                \\            // One arena for the whole connection, reset (not freed)
                \\            // between keep-alive requests: a fresh
                \\            // `ArenaAllocator.init`/`deinit` per request would mmap +
                \\            // munmap on every request, two syscalls in the hot path.
                \\            // `.retain_capacity` keeps the backing pages so steady
                \\            // state does zero allocation syscalls per request.
                \\            var conn_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                \\            defer conn_arena.deinit();
                \\            const carena = conn_arena.allocator();
                \\            conn: while (true) {
                \\                _ = conn_arena.reset(.retain_capacity);
                \\                const first = r.takeDelimiterInclusive('\n') catch break :conn;
                \\                const line = std.mem.trimEnd(u8, first, "\r\n");
                \\                var it = std.mem.tokenizeScalar(u8, line, ' ');
                \\                const method = it.next() orelse break :conn;
                \\                const path = it.next() orelse break :conn;
                \\                const hdrs = __httpReqHeaders(carena) orelse break :conn;
                \\                var content_length: usize = 0;
                \\                var keep_alive = true;
                \\                while (true) {
                \\                    const raw = r.takeDelimiterInclusive('\n') catch break;
                \\                    const h = std.mem.trimEnd(u8, raw, "\r\n");
                \\                    if (h.len == 0) break;
                \\                    const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
                \\                    const name = std.mem.trim(u8, h[0..colon], " \t");
                \\                    const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
                \\                    __httpReqHeader(hdrs, carena, name, value);
                \\                    if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                \\                        content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                \\                    } else if (std.ascii.eqlIgnoreCase(name, "connection") and std.ascii.eqlIgnoreCase(value, "close")) {
                \\                        keep_alive = false;
                \\                    }
                \\                }
                \\                const body = carena.alloc(u8, content_length) catch break :conn;
                \\                r.readSliceAll(body) catch break :conn;
                \\                const req: __LumenHttpRequest = .{
                \\                    .method = carena.dupe(u8, method) catch break :conn,
                \\                    .path = carena.dupe(u8, path) catch break :conn,
                \\                    .body = body,
                \\                    .headers = hdrs,
                \\                };
                \\                const res = self.handler.call(self.handler.ctx, req);
                \\                const conn_header: []const u8 = if (keep_alive) "keep-alive" else "close";
                \\                w.print("HTTP/1.1 {d} OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: {s}\r\n", .{ res.status, res.body.len, conn_header }) catch break :conn;
                \\                for (res.headers.keys_.items, res.headers.values_.items) |hk, hv| {
                \\                    w.print("{s}: {s}\r\n", .{ hk, hv }) catch break :conn;
                \\                }
                \\                w.writeAll("\r\n") catch break :conn;
                \\                w.writeAll(res.body) catch break :conn;
                \\                w.flush() catch break :conn;
                \\                if (!keep_alive) break :conn;
                \\            }
                \\        }
                \\    };
                \\    while (true) {
                \\        const stream = server.accept(io) catch continue;
                \\        const conn = std.heap.page_allocator.create(Conn) catch {
                \\            stream.close(io);
                \\            continue;
                \\        };
                \\        conn.* = .{ .io = io, .stream = stream, .handler = handler };
                \\        __http_pool.schedule(xev.ThreadPool.Batch.from(&conn.task));
                \\    }
                \\}
                \\
            );
            if (program.needs_http_server_stream) {
                // Streaming sibling of the loop above (spec 452): identical
                // accept/parse/keep-alive structure, but instead of writing
                // one buffered response after the handler returns, the
                // handler drives the wire itself through a ResponseWriter.
                // The buffered loop above stays byte-for-byte untouched; a
                // program using both forms gets both loops (each server call
                // is noreturn, so only one ever runs per process — the
                // streaming variant still gets its own pool variable to keep
                // the two definitions independent).
                //
                // Same documented trade-off as the buffered pool: a handler
                // that blocks on a slow upstream stream (the proxy shape)
                // occupies one worker for the stream's duration — the pool
                // is sized for I/O concurrency, not CPU count, exactly for
                // this.
                try out.appendSlice(arena,
                    \\var __http_stream_pool: xev.ThreadPool = undefined;
                    \\fn __httpCreateServerStream(io: std.Io, alloc: std.mem.Allocator, port: i32, handler: anytype) noreturn {
                    \\    _ = alloc;
                    \\    const addr = std.Io.net.IpAddress.parse("0.0.0.0", @intCast(port)) catch std.process.exit(1);
                    \\    var server = addr.listen(io, .{ .reuse_address = true }) catch std.process.exit(1);
                    \\    const __http_cpus: u32 = @intCast(std.Thread.getCpuCount() catch 1);
                    \\    __http_stream_pool = xev.ThreadPool.init(.{
                    \\        .max_threads = @max(4, __http_cpus * 2),
                    \\        .stack_size = 512 * 1024,
                    \\    });
                    \\    const Handler = @TypeOf(handler);
                    \\    const Conn = struct {
                    \\        task: xev.ThreadPool.Task = .{ .callback = run },
                    \\        io: std.Io,
                    \\        stream: std.Io.net.Stream,
                    \\        handler: Handler,
                    \\        fn run(t: *xev.ThreadPool.Task) void {
                    \\            const self: *@This() = @fieldParentPtr("task", t);
                    \\            defer std.heap.page_allocator.destroy(self);
                    \\            const io2 = self.io;
                    \\            const stream = self.stream;
                    \\            defer stream.close(io2);
                    \\            var read_buf: [16 * 1024]u8 = undefined;
                    \\            var reader = stream.reader(io2, &read_buf);
                    \\            const r = &reader.interface;
                    \\            var write_buf: [16 * 1024]u8 = undefined;
                    \\            var writer = stream.writer(io2, &write_buf);
                    \\            const w = &writer.interface;
                    \\            var conn_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    \\            defer conn_arena.deinit();
                    \\            const carena = conn_arena.allocator();
                    \\            conn: while (true) {
                    \\                _ = conn_arena.reset(.retain_capacity);
                    \\                const first = r.takeDelimiterInclusive('\n') catch break :conn;
                    \\                const line = std.mem.trimEnd(u8, first, "\r\n");
                    \\                var it = std.mem.tokenizeScalar(u8, line, ' ');
                    \\                const method = it.next() orelse break :conn;
                    \\                const path = it.next() orelse break :conn;
                    \\                const hdrs = __httpReqHeaders(carena) orelse break :conn;
                    \\                var content_length: usize = 0;
                    \\                var keep_alive = true;
                    \\                while (true) {
                    \\                    const raw = r.takeDelimiterInclusive('\n') catch break;
                    \\                    const h = std.mem.trimEnd(u8, raw, "\r\n");
                    \\                    if (h.len == 0) break;
                    \\                    const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
                    \\                    const name = std.mem.trim(u8, h[0..colon], " \t");
                    \\                    const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
                    \\                    __httpReqHeader(hdrs, carena, name, value);
                    \\                    if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                    \\                        content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                    \\                    } else if (std.ascii.eqlIgnoreCase(name, "connection") and std.ascii.eqlIgnoreCase(value, "close")) {
                    \\                        keep_alive = false;
                    \\                    }
                    \\                }
                    \\                const body = carena.alloc(u8, content_length) catch break :conn;
                    \\                r.readSliceAll(body) catch break :conn;
                    \\                const req: __LumenHttpRequest = .{
                    \\                    .method = carena.dupe(u8, method) catch break :conn,
                    \\                    .path = carena.dupe(u8, path) catch break :conn,
                    \\                    .body = body,
                    \\                    .headers = hdrs,
                    \\                };
                    \\                var rw: LumenResponseWriter = .{ .w = w, .keep_alive = keep_alive };
                    \\                self.handler.call(self.handler.ctx, req, &rw);
                    \\                // A handler that returns without end() gets it
                    \\                // called implicitly — a hung client is a bug,
                    \\                // not a possible outcome.
                    \\                if (!rw.ended) rw.end();
                    \\                if (!keep_alive) break :conn;
                    \\            }
                    \\        }
                    \\    };
                    \\    while (true) {
                    \\        const stream = server.accept(io) catch continue;
                    \\        const conn = std.heap.page_allocator.create(Conn) catch {
                    \\            stream.close(io);
                    \\            continue;
                    \\        };
                    \\        conn.* = .{ .io = io, .stream = stream, .handler = handler };
                    \\        __http_stream_pool.schedule(xev.ThreadPool.Batch.from(&conn.task));
                    \\    }
                    \\}
                    \\
                );
            }
        } else {
            // wasm32-wasi: no real OS threads, and the CLI's own libxev-
            // wiring gate hard-fails any wasm build that references
            // `@import("xev")` at all (async isn't supported there yet, see
            // `compileFile` in lumen.zig) -- so this target keeps the
            // original single-connection-at-a-time loop rather than the
            // thread-pool version above. Matches this function's own
            // pre-spec-049 behavior exactly, not a new limitation.
            try out.appendSlice(arena,
                \\fn __httpCreateServer(io: std.Io, alloc: std.mem.Allocator, port: i32, handler: anytype) noreturn {
                \\    _ = alloc;
                \\    const addr = std.Io.net.IpAddress.parse("0.0.0.0", @intCast(port)) catch std.process.exit(1);
                \\    var server = addr.listen(io, .{ .reuse_address = true }) catch std.process.exit(1);
                \\    while (true) {
                \\        const stream = server.accept(io) catch continue;
                \\        defer stream.close(io);
                \\        var read_buf: [16 * 1024]u8 = undefined;
                \\        var reader = stream.reader(io, &read_buf);
                \\        const r = &reader.interface;
                \\        var write_buf: [16 * 1024]u8 = undefined;
                \\        var writer = stream.writer(io, &write_buf);
                \\        const w = &writer.interface;
                \\        conn: while (true) {
                \\            var conn_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                \\            defer conn_arena.deinit();
                \\            const carena = conn_arena.allocator();
                \\            const first = r.takeDelimiterInclusive('\n') catch break :conn;
                \\            const line = std.mem.trimEnd(u8, first, "\r\n");
                \\            var it = std.mem.tokenizeScalar(u8, line, ' ');
                \\            const method = it.next() orelse break :conn;
                \\            const path = it.next() orelse break :conn;
                \\            const hdrs = __httpReqHeaders(carena) orelse break :conn;
                \\            var content_length: usize = 0;
                \\            var keep_alive = true;
                \\            while (true) {
                \\                const raw = r.takeDelimiterInclusive('\n') catch break;
                \\                const h = std.mem.trimEnd(u8, raw, "\r\n");
                \\                if (h.len == 0) break;
                \\                const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
                \\                const name = std.mem.trim(u8, h[0..colon], " \t");
                \\                const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
                \\                __httpReqHeader(hdrs, carena, name, value);
                \\                if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                \\                    content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                \\                } else if (std.ascii.eqlIgnoreCase(name, "connection") and std.ascii.eqlIgnoreCase(value, "close")) {
                \\                    keep_alive = false;
                \\                }
                \\            }
                \\            const body = carena.alloc(u8, content_length) catch break :conn;
                \\            r.readSliceAll(body) catch break :conn;
                \\            const req: __LumenHttpRequest = .{
                \\                .method = carena.dupe(u8, method) catch break :conn,
                \\                .path = carena.dupe(u8, path) catch break :conn,
                \\                .body = body,
                \\                .headers = hdrs,
                \\            };
                \\            const res = handler.call(handler.ctx, req);
                \\            const conn_header: []const u8 = if (keep_alive) "keep-alive" else "close";
                \\            w.print("HTTP/1.1 {d} OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: {s}\r\n", .{ res.status, res.body.len, conn_header }) catch break :conn;
                \\            for (res.headers.keys_.items, res.headers.values_.items) |hk, hv| {
                \\                w.print("{s}: {s}\r\n", .{ hk, hv }) catch break :conn;
                \\            }
                \\            w.writeAll("\r\n") catch break :conn;
                \\            w.writeAll(res.body) catch break :conn;
                \\            w.flush() catch break :conn;
                \\            if (!keep_alive) break :conn;
                \\        }
                \\    }
                \\}
                \\
            );
            if (program.needs_http_server_stream) {
                // Streaming sibling for the single-threaded wasm fallback
                // loop (spec 452): the streaming form needs no threads at
                // all — the handler runs synchronously and its writes are
                // framed and flushed straight to the socket — so wasm gets
                // the same semantics as the thread-pool build, never a
                // silent buffer.
                try out.appendSlice(arena,
                    \\fn __httpCreateServerStream(io: std.Io, alloc: std.mem.Allocator, port: i32, handler: anytype) noreturn {
                    \\    _ = alloc;
                    \\    const addr = std.Io.net.IpAddress.parse("0.0.0.0", @intCast(port)) catch std.process.exit(1);
                    \\    var server = addr.listen(io, .{ .reuse_address = true }) catch std.process.exit(1);
                    \\    while (true) {
                    \\        const stream = server.accept(io) catch continue;
                    \\        defer stream.close(io);
                    \\        var read_buf: [16 * 1024]u8 = undefined;
                    \\        var reader = stream.reader(io, &read_buf);
                    \\        const r = &reader.interface;
                    \\        var write_buf: [16 * 1024]u8 = undefined;
                    \\        var writer = stream.writer(io, &write_buf);
                    \\        const w = &writer.interface;
                    \\        conn: while (true) {
                    \\            var conn_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    \\            defer conn_arena.deinit();
                    \\            const carena = conn_arena.allocator();
                    \\            const first = r.takeDelimiterInclusive('\n') catch break :conn;
                    \\            const line = std.mem.trimEnd(u8, first, "\r\n");
                    \\            var it = std.mem.tokenizeScalar(u8, line, ' ');
                    \\            const method = it.next() orelse break :conn;
                    \\            const path = it.next() orelse break :conn;
                    \\            const hdrs = __httpReqHeaders(carena) orelse break :conn;
                    \\            var content_length: usize = 0;
                    \\            var keep_alive = true;
                    \\            while (true) {
                    \\                const raw = r.takeDelimiterInclusive('\n') catch break;
                    \\                const h = std.mem.trimEnd(u8, raw, "\r\n");
                    \\                if (h.len == 0) break;
                    \\                const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
                    \\                const name = std.mem.trim(u8, h[0..colon], " \t");
                    \\                const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
                    \\                __httpReqHeader(hdrs, carena, name, value);
                    \\                if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                    \\                    content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                    \\                } else if (std.ascii.eqlIgnoreCase(name, "connection") and std.ascii.eqlIgnoreCase(value, "close")) {
                    \\                    keep_alive = false;
                    \\                }
                    \\            }
                    \\            const body = carena.alloc(u8, content_length) catch break :conn;
                    \\            r.readSliceAll(body) catch break :conn;
                    \\            const req: __LumenHttpRequest = .{
                    \\                .method = carena.dupe(u8, method) catch break :conn,
                    \\                .path = carena.dupe(u8, path) catch break :conn,
                    \\                .body = body,
                    \\                .headers = hdrs,
                    \\            };
                    \\            var rw: LumenResponseWriter = .{ .w = w, .keep_alive = keep_alive };
                    \\            handler.call(handler.ctx, req, &rw);
                    \\            if (!rw.ended) rw.end();
                    \\            if (!keep_alive) break :conn;
                    \\        }
                    \\    }
                    \\}
                    \\
                );
            }
        }
    }
    if (program.needs_net) {
        // net.connect/net.createServer (spec 054): raw TCP, the layer
        // http's own client/server are already built on but didn't expose
        // directly to Lumen source. LumenSocket wraps a std.Io.net.Stream
        // exactly the way LumenReadableStream/LumenWritableStream (spec
        // 046) wrap a std.Io.File -- an optional stream (null for a
        // failed/refused connect) plus heap-allocated reader/writer
        // buffers via __sa(), degrading to "always read empty, write is a
        // no-op" rather than crashing on a dead connection, the same
        // fallback convention every fs-stream/http path already uses.
        // close() is idempotent (`closed` flag) because
        // net.createServer's accept loop always closes the socket after
        // the handler returns, whether or not the handler already closed
        // it itself.
        try out.appendSlice(arena,
            \\pub const LumenSocket = struct {
            \\    stream: ?std.Io.net.Stream,
            \\    io: std.Io,
            \\    reader: std.Io.net.Stream.Reader = undefined,
            \\    writer: std.Io.net.Stream.Writer = undefined,
            \\    closed: bool = false,
            \\    fn __init(io: std.Io, stream: ?std.Io.net.Stream) *LumenSocket {
            \\        const p = __sa().create(LumenSocket) catch unreachable;
            \\        p.* = .{ .stream = stream, .io = io };
            \\        if (stream) |s| {
            \\            const rbuf = __sa().alloc(u8, 65536) catch unreachable;
            \\            p.reader = s.reader(io, rbuf);
            \\            const wbuf = __sa().alloc(u8, 65536) catch unreachable;
            \\            p.writer = s.writer(io, wbuf);
            \\        }
            \\        return p;
            \\    }
            \\    fn read(self: *LumenSocket) []const u8 {
            \\        if (self.stream == null or self.closed) return "";
            \\        var scratch: [65536]u8 = undefined;
            \\        const n = self.reader.interface.readSliceShort(&scratch) catch return "";
            \\        if (n == 0) return "";
            \\        return __sa().dupe(u8, scratch[0..n]) catch "";
            \\    }
            \\    fn write(self: *LumenSocket, chunk: []const u8) void {
            \\        if (self.stream == null or self.closed) return;
            \\        self.writer.interface.writeAll(chunk) catch return;
            \\        // Flushes on every call, unlike WritableStream (which defers
            \\        // to .close()): a long-lived socket conversation has no
            \\        // single "I'm done" moment the way a one-shot file write
            \\        // does, so buffering until some later .close() would mean
            \\        // the peer never sees the bytes in time. Matches
            \\        // http.createServer's own per-response w.flush() call.
            \\        self.writer.interface.flush() catch {};
            \\    }
            \\    fn close(self: *LumenSocket) void {
            \\        if (self.closed) return;
            \\        self.closed = true;
            \\        if (self.stream) |s| {
            \\            self.writer.interface.flush() catch {};
            \\            s.close(self.io);
            \\        }
            \\    }
            \\};
            \\
        );
        if (program.needs_net_client) {
            try out.appendSlice(arena,
                \\fn __netConnect(io: std.Io, host: []const u8, port: i32) *LumenSocket {
                \\    const hn = std.Io.net.HostName.init(host) catch return LumenSocket.__init(io, null);
                \\    const stream = hn.connect(io, @intCast(port), .{ .mode = .stream }) catch return LumenSocket.__init(io, null);
                \\    return LumenSocket.__init(io, stream);
                \\}
                \\
            );
        }
        if (program.needs_net_server) {
            // Single connection at a time for v1 (spec 054's documented
            // scope, not yet given the spec 049 xev.ThreadPool treatment
            // http.createServer got -- no benchmark or prior request/
            // response cadence exists yet to justify it for raw bytes).
            // Mirrors __httpCreateServer's non-threadpool branch exactly.
            try out.appendSlice(arena,
                \\fn __netCreateServer(io: std.Io, alloc: std.mem.Allocator, port: i32, handler: anytype) noreturn {
                \\    _ = alloc;
                \\    const addr = std.Io.net.IpAddress.parse("0.0.0.0", @intCast(port)) catch std.process.exit(1);
                \\    var server = addr.listen(io, .{ .reuse_address = true }) catch std.process.exit(1);
                \\    while (true) {
                \\        const stream = server.accept(io) catch continue;
                \\        const sock = LumenSocket.__init(io, stream);
                \\        handler.call(handler.ctx, sock);
                \\        sock.close();
                \\    }
                \\}
                \\
            );
        }
    }
    if (program.needs_http_constants) {
        // http.METHODS/STATUS_CODES (spec 049): plain constant data, the
        // real lists Node itself uses -- METHODS from llhttp's own
        // HTTP_METHOD_MAP (checked directly against
        // deps/llhttp/include/llhttp.h in Node's own source, not
        // guessed), alphabetically sorted, matching Node's actual runtime
        // `http.METHODS` output (`methods.slice().sort()`); STATUS_CODES
        // from Node's lib/_http_server.js STATUS_CODES object, verbatim.
        // STATUS_CODES returns `Map<int, string>`, constructed the same
        // way spec 045 first proved a stdlib builtin safely can (build a
        // `LumenMap` internally, `.set()` in a loop, hand back the
        // pointer).
        try out.appendSlice(arena,
            \\fn __httpMethods() []const []const u8 {
            \\    return &.{
            \\        "ACL",       "BIND",     "CHECKOUT", "CONNECT",     "COPY",       "DELETE",
            \\        "GET",       "HEAD",     "LINK",     "LOCK",        "M-SEARCH",   "MERGE",
            \\        "MKACTIVITY", "MKCALENDAR", "MKCOL", "MOVE",        "NOTIFY",     "OPTIONS",
            \\        "PATCH",     "POST",     "PROPFIND", "PROPPATCH",   "PURGE",      "PUT",
            \\        "QUERY",     "REBIND",   "REPORT",   "SEARCH",      "SOURCE",     "SUBSCRIBE",
            \\        "TRACE",     "UNBIND",   "UNLINK",   "UNLOCK",      "UNSUBSCRIBE",
            \\    };
            \\}
            \\fn __httpStatusCodes() *LumenMap(i32, []const u8) {
            \\    const m = LumenMap(i32, []const u8).__init();
            \\    const entries = [_]struct { code: i32, reason: []const u8 }{
            \\        .{ .code = 100, .reason = "Continue" },
            \\        .{ .code = 101, .reason = "Switching Protocols" },
            \\        .{ .code = 102, .reason = "Processing" },
            \\        .{ .code = 103, .reason = "Early Hints" },
            \\        .{ .code = 200, .reason = "OK" },
            \\        .{ .code = 201, .reason = "Created" },
            \\        .{ .code = 202, .reason = "Accepted" },
            \\        .{ .code = 203, .reason = "Non-Authoritative Information" },
            \\        .{ .code = 204, .reason = "No Content" },
            \\        .{ .code = 205, .reason = "Reset Content" },
            \\        .{ .code = 206, .reason = "Partial Content" },
            \\        .{ .code = 207, .reason = "Multi-Status" },
            \\        .{ .code = 208, .reason = "Already Reported" },
            \\        .{ .code = 226, .reason = "IM Used" },
            \\        .{ .code = 300, .reason = "Multiple Choices" },
            \\        .{ .code = 301, .reason = "Moved Permanently" },
            \\        .{ .code = 302, .reason = "Found" },
            \\        .{ .code = 303, .reason = "See Other" },
            \\        .{ .code = 304, .reason = "Not Modified" },
            \\        .{ .code = 305, .reason = "Use Proxy" },
            \\        .{ .code = 307, .reason = "Temporary Redirect" },
            \\        .{ .code = 308, .reason = "Permanent Redirect" },
            \\        .{ .code = 400, .reason = "Bad Request" },
            \\        .{ .code = 401, .reason = "Unauthorized" },
            \\        .{ .code = 402, .reason = "Payment Required" },
            \\        .{ .code = 403, .reason = "Forbidden" },
            \\        .{ .code = 404, .reason = "Not Found" },
            \\        .{ .code = 405, .reason = "Method Not Allowed" },
            \\        .{ .code = 406, .reason = "Not Acceptable" },
            \\        .{ .code = 407, .reason = "Proxy Authentication Required" },
            \\        .{ .code = 408, .reason = "Request Timeout" },
            \\        .{ .code = 409, .reason = "Conflict" },
            \\        .{ .code = 410, .reason = "Gone" },
            \\        .{ .code = 411, .reason = "Length Required" },
            \\        .{ .code = 412, .reason = "Precondition Failed" },
            \\        .{ .code = 413, .reason = "Payload Too Large" },
            \\        .{ .code = 414, .reason = "URI Too Long" },
            \\        .{ .code = 415, .reason = "Unsupported Media Type" },
            \\        .{ .code = 416, .reason = "Range Not Satisfiable" },
            \\        .{ .code = 417, .reason = "Expectation Failed" },
            \\        .{ .code = 418, .reason = "I'm a Teapot" },
            \\        .{ .code = 421, .reason = "Misdirected Request" },
            \\        .{ .code = 422, .reason = "Unprocessable Entity" },
            \\        .{ .code = 423, .reason = "Locked" },
            \\        .{ .code = 424, .reason = "Failed Dependency" },
            \\        .{ .code = 425, .reason = "Too Early" },
            \\        .{ .code = 426, .reason = "Upgrade Required" },
            \\        .{ .code = 428, .reason = "Precondition Required" },
            \\        .{ .code = 429, .reason = "Too Many Requests" },
            \\        .{ .code = 431, .reason = "Request Header Fields Too Large" },
            \\        .{ .code = 451, .reason = "Unavailable For Legal Reasons" },
            \\        .{ .code = 500, .reason = "Internal Server Error" },
            \\        .{ .code = 501, .reason = "Not Implemented" },
            \\        .{ .code = 502, .reason = "Bad Gateway" },
            \\        .{ .code = 503, .reason = "Service Unavailable" },
            \\        .{ .code = 504, .reason = "Gateway Timeout" },
            \\        .{ .code = 505, .reason = "HTTP Version Not Supported" },
            \\        .{ .code = 506, .reason = "Variant Also Negotiates" },
            \\        .{ .code = 507, .reason = "Insufficient Storage" },
            \\        .{ .code = 508, .reason = "Loop Detected" },
            \\        .{ .code = 509, .reason = "Bandwidth Limit Exceeded" },
            \\        .{ .code = 510, .reason = "Not Extended" },
            \\        .{ .code = 511, .reason = "Network Authentication Required" },
            \\    };
            \\    for (entries) |e| m.set(e.code, e.reason);
            \\    return m;
            \\}
            \\
        );
    }
    if (program.needs_json) {
        // JSON.stringify/JSON.parse<T> (spec 051): thin wrappers around
        // std.json's own automatic struct/slice reflection. Lumen record
        // types already lower to real Zig structs with matching field
        // names, confirmed directly (not assumed) that
        // Stringify.valueAlloc/parseFromSlice both round-trip an arbitrary
        // struct correctly with zero custom (de)serialization code. Parse
        // failures fall back to std.mem.zeroes(T), the same "fallback,
        // don't crash" shape every other fallible builtin here uses --
        // for a string field this is a valid empty slice, not a null
        // dereference risk (confirmed, not assumed). The Parsed(T)
        // wrapper's own arena is deliberately never deinit'd, matching
        // this runtime's established "arena everything, reclaim on exit"
        // convention elsewhere.
        try out.appendSlice(arena,
            \\fn __jsonStringify(alloc: std.mem.Allocator, value: anytype) []const u8 {
            \\    return std.json.Stringify.valueAlloc(alloc, value, .{}) catch "";
            \\}
            \\fn __jsonStringifyPretty(alloc: std.mem.Allocator, value: anytype, indent: usize) []const u8 {
            \\    // JSON.stringify(v, null, n): std's indent width is a comptime enum,
            \\    // so map the runtime count to the nearest supported option.
            \\    return switch (indent) {
            \\        0 => std.json.Stringify.valueAlloc(alloc, value, .{}),
            \\        1 => std.json.Stringify.valueAlloc(alloc, value, .{ .whitespace = .indent_1 }),
            \\        2 => std.json.Stringify.valueAlloc(alloc, value, .{ .whitespace = .indent_2 }),
            \\        3 => std.json.Stringify.valueAlloc(alloc, value, .{ .whitespace = .indent_3 }),
            \\        4 => std.json.Stringify.valueAlloc(alloc, value, .{ .whitespace = .indent_4 }),
            \\        else => std.json.Stringify.valueAlloc(alloc, value, .{ .whitespace = .indent_8 }),
            \\    } catch "";
            \\}
            \\
        );
        if (options.runtime_locations) {
            // Invalid JSON raises a catchable Lumen exception (spec 252),
            // matching JS's SyntaxError instead of silently zeroing the value.
            try out.appendSlice(arena,
                \\fn __jsonParse(comptime T: type, alloc: std.mem.Allocator, text: []const u8) error{LumenThrow}!T {
                \\    const parsed = std.json.parseFromSlice(T, alloc, text, .{}) catch |e| {
                \\        __lumen_err_msg = std.fmt.allocPrint(alloc, "JSON.parse: invalid JSON ({s})", .{@errorName(e)}) catch "JSON.parse: invalid JSON";
                \\        __lumen_throwing = true;
                \\        return error.LumenThrow;
                \\    };
                \\    return parsed.value;
                \\}
                \\
            );
        } else {
            try out.appendSlice(arena,
                \\fn __jsonParse(comptime T: type, alloc: std.mem.Allocator, text: []const u8) T {
                \\    const parsed = std.json.parseFromSlice(T, alloc, text, .{}) catch return std.mem.zeroes(T);
                \\    return parsed.value;
                \\}
                \\
            );
        }
    }
}

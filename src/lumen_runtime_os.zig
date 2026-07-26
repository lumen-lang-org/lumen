//! Runtime prelude codegen for stdio/process/OS surfaces: process
//! stdin/stdout/stderr streams, readline, Buffer, path, URL, child_process,
//! assert, time, console-to-stdout, process/os APIs, crypto, and zlib.
//!
//! Extracted from `lumen_compiler.zig` purely by size: each `emit*` function
//! appends the same gated runtime-prelude Zig source blocks it always did,
//! in the same order, driven by the `program.needs_*` flags the checker set.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const CompileOptions = @import("lumen_emit.zig").CompileOptions;
const CompileError = @import("lumen_diag.zig").CompileError;

pub fn emitStdioRuntime(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), program: *const ast.Program, options: CompileOptions) CompileError!void {
    _ = options;
    if (program.needs_process_stdio) {
        // process.stdin()/stdout()/stderr() (spec 053): the exact spec
        // 046 stream types, just constructed straight from the real stdio
        // File instead of an opened path -- see spec.md's "Why reuse spec
        // 046's types verbatim" section.
        try out.appendSlice(arena,
            \\fn __processStdin(io: std.Io) *LumenReadableStream {
            \\    return LumenReadableStream.__init(io, std.Io.File.stdin());
            \\}
            \\fn __processStdout(io: std.Io) *LumenWritableStream {
            \\    const s = LumenWritableStream.__init(io, std.Io.File.stdout());
            \\    s.flush_each_write = true;
            \\    return s;
            \\}
            \\fn __processStderr(io: std.Io) *LumenWritableStream {
            \\    const s = LumenWritableStream.__init(io, std.Io.File.stderr());
            \\    s.flush_each_write = true;
            \\    return s;
            \\}
            \\
        );
    }
    if (program.needs_readline) {
        // readline.question (spec 058): a thin, synchronous wrapper over
        // process.stdout()/stdin(), both already shipped by spec 053 --
        // see spec.md's "why one flat function". Strips exactly one
        // trailing \r\n or \n that readLine() deliberately keeps (its own
        // blank-line-vs-EOF fix), since question()'s return value should
        // be "what the user typed", not a line-with-terminator.
        try out.appendSlice(arena,
            \\var __readline_stdin: ?*LumenReadableStream = null;
            \\fn __readlineQuestion(io: std.Io, prompt: []const u8) []const u8 {
            \\    __processStdout(io).write(prompt);
            \\    // A fresh LumenReadableStream per call (like process.stdin()
            \\    // itself) would each open its own std.Io.File.Reader with its
            \\    // own internal read-ahead buffer -- the first call's buffer
            \\    // can silently swallow bytes belonging to the *next* line
            \\    // straight from the pipe, which the next call's brand-new,
            \\    // empty buffer never sees. Confirmed directly: a two-line
            \\    // heredoc lost its second line before this fix. One shared
            \\    // instance across every question() call in the program
            \\    // keeps the same underlying reader (and its buffer) alive.
            \\    if (__readline_stdin == null) __readline_stdin = __processStdin(io);
            \\    var line = __readline_stdin.?.readLine();
            \\    if (line.len == 0) return "";
            \\    if (line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
            \\    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            \\    return line;
            \\}
            \\
        );
    }
    if (program.needs_buffer) {
        // Buffer (spec 056): a dedicated heap-pointer type over `[]const u8`,
        // built the same way Map/Set/ReadableStream are -- allocated via
        // __sa(), the stable arena every other container already uses.
        // `.length` is a real Zig method (`length()`), not a raw `.data.len`
        // field read, matching Map/Set's `.size` -> `.size()` shape (Buffer
        // is heap-pointer-wrapped, not a raw slice, at the Lumen type
        // level) -- see spec.md's design notes for why this precedent was
        // picked over string/array's raw-slice `.length`.
        try out.appendSlice(arena,
            \\pub const LumenBuffer = struct {
            \\    data: []const u8,
            \\    fn __wrap(bytes: []const u8) *LumenBuffer {
            \\        const p = __sa().create(LumenBuffer) catch unreachable;
            \\        p.* = .{ .data = bytes };
            \\        return p;
            \\    }
            \\    fn length(self: *LumenBuffer) i32 {
            \\        return @as(i32, @intCast(self.data.len));
            \\    }
            \\    fn at(self: *LumenBuffer, i: i32) i32 {
            \\        if (i < 0 or i >= @as(i32, @intCast(self.data.len))) return 0;
            \\        return @as(i32, self.data[@intCast(i)]);
            \\    }
            \\    fn slice(self: *LumenBuffer, start: i32, end: i32) *LumenBuffer {
            \\        const len = @as(i32, @intCast(self.data.len));
            \\        var s = start;
            \\        var e = end;
            \\        if (s < 0) s = 0;
            \\        if (s > len) s = len;
            \\        if (e < 0) e = 0;
            \\        if (e > len) e = len;
            \\        if (e < s) e = s;
            \\        return LumenBuffer.__wrap(self.data[@intCast(s)..@intCast(e)]);
            \\    }
            \\    fn equals(self: *LumenBuffer, other: *LumenBuffer) bool {
            \\        return std.mem.eql(u8, self.data, other.data);
            \\    }
            \\    fn toString(self: *LumenBuffer, encoding: []const u8) []const u8 {
            \\        if (std.mem.eql(u8, encoding, "hex")) {
            \\            return std.fmt.allocPrint(__sa(), "{x}", .{self.data}) catch "";
            \\        }
            \\        if (std.mem.eql(u8, encoding, "base64")) {
            \\            const enc = std.base64.standard.Encoder;
            \\            const n = enc.calcSize(self.data.len);
            \\            const buf = __sa().alloc(u8, n) catch return "";
            \\            return enc.encode(buf, self.data);
            \\        }
            \\        return self.data;
            \\    }
            \\};
            \\fn __bufferFromUtf8(s: []const u8) *LumenBuffer {
            \\    return LumenBuffer.__wrap(s);
            \\}
            \\fn __bufferFromEncoded(s: []const u8, encoding: []const u8) *LumenBuffer {
            \\    if (std.mem.eql(u8, encoding, "hex")) {
            \\        if (s.len % 2 != 0) return LumenBuffer.__wrap("");
            \\        const n = s.len / 2;
            \\        const buf = __sa().alloc(u8, n) catch return LumenBuffer.__wrap("");
            \\        _ = std.fmt.hexToBytes(buf, s) catch return LumenBuffer.__wrap("");
            \\        return LumenBuffer.__wrap(buf);
            \\    }
            \\    if (std.mem.eql(u8, encoding, "base64")) {
            \\        const dec = std.base64.standard.Decoder;
            \\        const dlen = dec.calcSizeForSlice(s) catch return LumenBuffer.__wrap("");
            \\        const buf = __sa().alloc(u8, dlen) catch return LumenBuffer.__wrap("");
            \\        dec.decode(buf, s) catch return LumenBuffer.__wrap("");
            \\        return LumenBuffer.__wrap(buf);
            \\    }
            \\    return LumenBuffer.__wrap(s);
            \\}
            \\fn __bufferAlloc(n: i32) *LumenBuffer {
            \\    const size: usize = if (n < 0) 0 else @intCast(n);
            \\    const buf = __sa().alloc(u8, size) catch unreachable;
            \\    @memset(buf, 0);
            \\    return LumenBuffer.__wrap(buf);
            \\}
            \\
        );
    }
    if (program.needs_path_api) {
        // path.* (spec 032): pure string manipulation, no Io parameter at all
        // -- the one stdlib namespace that doesn't thread `io` through.
        // __pathJoin/__pathResolve/normalize all reduce to std.fs.path.resolve:
        // its "cd"-chaining behavior (an absolute segment resets the result,
        // "." and ".." collapse without ever consulting a real working
        // directory) is exactly Node's path.resolve semantics, *except* Node
        // implicitly anchors a fully-relative input to process.cwd() and Zig
        // does not (this Zig version has no working Io.Dir.realpath to get a
        // real cwd string from, the same gap documented for fs.realpathSync).
        try out.appendSlice(arena,
            \\pub const __LumenPathParts = struct { root: []const u8, dir: []const u8, base: []const u8, name: []const u8, ext: []const u8 };
            \\fn __pathBasename(path: []const u8, suffix: []const u8) []const u8 {
            \\    const base = std.fs.path.basename(path);
            \\    if (suffix.len > 0 and base.len > suffix.len and std.mem.endsWith(u8, base, suffix)) {
            \\        return base[0 .. base.len - suffix.len];
            \\    }
            \\    return base;
            \\}
            \\fn __pathDirname(path: []const u8) []const u8 {
            \\    return std.fs.path.dirname(path) orelse ".";
            \\}
            \\fn __pathResolve(io: std.Io, alloc: std.mem.Allocator, paths: []const []const u8) []const u8 {
            \\    // path.resolve (spec 032 revisited): now anchors a fully-
            \\    // relative result to the real cwd, matching Node. Always
            \\    // prepending cwd and letting std.fs.path.resolve's own
            \\    // left-to-right "cd"-chaining logic run is enough -- if a
            \\    // later segment is absolute, that logic already resets the
            \\    // result past the cwd anchor on its own, so there's no need
            \\    // to separately check whether any input is absolute first.
            \\    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            \\    const cwd_len = std.process.currentPath(io, &cwd_buf) catch {
            \\        return std.fs.path.resolve(alloc, paths) catch "";
            \\    };
            \\    const full = alloc.alloc([]const u8, paths.len + 1) catch return std.fs.path.resolve(alloc, paths) catch "";
            \\    full[0] = cwd_buf[0..cwd_len];
            \\    @memcpy(full[1..], paths);
            \\    return std.fs.path.resolve(alloc, full) catch "";
            \\}
            \\fn __pathJoin(alloc: std.mem.Allocator, paths: []const []const u8) []const u8 {
            \\    const naive = std.fs.path.join(alloc, paths) catch return "";
            \\    return std.fs.path.resolve(alloc, &.{naive}) catch naive;
            \\}
            \\fn __pathParse(path: []const u8) __LumenPathParts {
            \\    const ext = std.fs.path.extension(path);
            \\    const base = std.fs.path.basename(path);
            \\    return .{
            \\        .root = if (std.fs.path.isAbsolute(path)) "/" else "",
            \\        .dir = std.fs.path.dirname(path) orelse "",
            \\        .base = base,
            \\        .name = base[0 .. base.len - ext.len],
            \\        .ext = ext,
            \\    };
            \\}
            \\fn __pathFormat(alloc: std.mem.Allocator, parts: __LumenPathParts) []const u8 {
            \\    const dir = if (parts.dir.len > 0) parts.dir else parts.root;
            \\    const base = if (parts.base.len > 0) parts.base else std.fmt.allocPrint(alloc, "{s}{s}", .{ parts.name, parts.ext }) catch "";
            \\    if (dir.len == 0) return base;
            \\    if (dir[dir.len - 1] == '/') return std.fmt.allocPrint(alloc, "{s}{s}", .{ dir, base }) catch base;
            \\    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, base }) catch base;
            \\}
            \\
        );
    }
    if (program.needs_url_api) {
        // url.* (spec 036): the runtime's own URI type (the same one used
        // elsewhere for HTTP requests) does the real parsing; this just walks
        // its already-decoded component fields into a plain record. Pure
        // string work otherwise, same as path -- no syscalls, works
        // identically on the native and wasm targets.
        try out.appendSlice(arena,
            \\pub const __LumenUrlParts = struct { protocol: []const u8, hostname: []const u8, port: []const u8, pathname: []const u8, search: []const u8, hash: []const u8, href: []const u8, query: *LumenMap([]const u8, []const u8) };
            \\fn __urlParseQuery(alloc: std.mem.Allocator, search: []const u8) *LumenMap([]const u8, []const u8) {
            \\    const m = LumenMap([]const u8, []const u8).__init();
            \\    const q = if (search.len > 0 and search[0] == '?') search[1..] else search;
            \\    var it = std.mem.tokenizeScalar(u8, q, '&');
            \\    while (it.next()) |pair| {
            \\        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            \\        const key = alloc.dupe(u8, pair[0..eq]) catch continue;
            \\        const value = alloc.dupe(u8, pair[eq + 1 ..]) catch continue;
            \\        m.set(key, value);
            \\    }
            \\    return m;
            \\}
            \\fn __urlParse(alloc: std.mem.Allocator, str: []const u8) __LumenUrlParts {
            \\    const href = alloc.dupe(u8, str) catch str;
            \\    const parsed = std.Uri.parse(str) catch return .{
            \\        .protocol = "", .hostname = "", .port = "", .pathname = "/", .search = "", .hash = "", .href = href,
            \\        .query = LumenMap([]const u8, []const u8).__init(),
            \\    };
            \\    const protocol = std.fmt.allocPrint(alloc, "{s}:", .{parsed.scheme}) catch "";
            \\    const hostname = if (parsed.host) |h| (h.toRawMaybeAlloc(alloc) catch "") else "";
            \\    const port = if (parsed.port) |p| (std.fmt.allocPrint(alloc, "{d}", .{p}) catch "") else "";
            \\    const raw_path = parsed.path.toRawMaybeAlloc(alloc) catch "/";
            \\    const pathname = if (raw_path.len == 0) "/" else raw_path;
            \\    const search = if (parsed.query) |q| (std.fmt.allocPrint(alloc, "?{s}", .{q.toRawMaybeAlloc(alloc) catch ""}) catch "") else "";
            \\    const hash = if (parsed.fragment) |f| (std.fmt.allocPrint(alloc, "#{s}", .{f.toRawMaybeAlloc(alloc) catch ""}) catch "") else "";
            \\    return .{
            \\        .protocol = protocol,
            \\        .hostname = hostname,
            \\        .port = port,
            \\        .pathname = pathname,
            \\        .search = search,
            \\        .hash = hash,
            \\        .href = href,
            \\        .query = __urlParseQuery(alloc, search),
            \\    };
            \\}
            \\fn __urlFormat(alloc: std.mem.Allocator, parts: __LumenUrlParts) []const u8 {
            \\    const host_port = if (parts.port.len > 0) (std.fmt.allocPrint(alloc, "{s}:{s}", .{ parts.hostname, parts.port }) catch parts.hostname) else parts.hostname;
            \\    return std.fmt.allocPrint(alloc, "{s}//{s}{s}{s}{s}", .{ parts.protocol, host_port, parts.pathname, parts.search, parts.hash }) catch "";
            \\}
            \\
        );
    }
    if (program.needs_child_process_api) {
        // child_process.spawnSync (spec 037): stdout and stderr are read to
        // completion sequentially, then wait() -- a command that writes more
        // than one pipe buffer (~64KB on Linux) to stderr while this is still
        // blocked reading stdout could deadlock. Documented, accepted v1
        // trade-off: real commands' stderr output is typically small.
        try out.appendSlice(arena,
            \\pub const __LumenSpawnResult = struct { stdout: []const u8, stderr: []const u8, status: i32 };
            \\fn __spawnSync(io: std.Io, alloc: std.mem.Allocator, command: []const u8, args: []const []const u8) __LumenSpawnResult {
            \\    const argv = alloc.alloc([]const u8, 1 + args.len) catch return .{ .stdout = "", .stderr = "", .status = -1 };
            \\    argv[0] = command;
            \\    for (args, 0..) |a, i| argv[i + 1] = a;
            \\    var child = std.process.spawn(io, .{
            \\        .argv = argv,
            \\        .stdin = .ignore,
            \\        .stdout = .pipe,
            \\        .stderr = .pipe,
            \\    }) catch return .{ .stdout = "", .stderr = "", .status = -1 };
            \\    var out_buf: [4096]u8 = undefined;
            \\    var out_reader = child.stdout.?.reader(io, &out_buf);
            \\    const stdout_data = out_reader.interface.allocRemaining(alloc, .limited(16 * 1024 * 1024)) catch &.{};
            \\    var err_buf: [4096]u8 = undefined;
            \\    var err_reader = child.stderr.?.reader(io, &err_buf);
            \\    const stderr_data = err_reader.interface.allocRemaining(alloc, .limited(16 * 1024 * 1024)) catch &.{};
            \\    const term = child.wait(io) catch return .{ .stdout = stdout_data, .stderr = stderr_data, .status = -1 };
            \\    const status: i32 = switch (term) {
            \\        .exited => |code| code,
            \\        else => -1,
            \\    };
            \\    return .{ .stdout = stdout_data, .stderr = stderr_data, .status = status };
            \\}
            \\
        );
    }
    if (program.needs_child_process_spawn) {
        // child_process.spawn (spec 450): a PERSISTENT piped subprocess, the
        // long-lived counterpart to spawnSync. Modeled on LumenSocket (spec
        // 054): a heap-allocated handle holding an optional std.process.Child
        // plus a buffered stdin writer and stdout reader kept ON the handle so
        // readLine() pulls one \n-delimited line at a time across many
        // exchanges instead of draining stdout to completion. A failed spawn
        // degrades to a no-op handle (child == null) rather than crashing, the
        // same convention LumenSocket's `stream: ?...` uses.
        //
        // stderr is INHERITED, not piped: readLine only drains stdout, so an
        // undrained stderr pipe would deadlock the child once it backs up ~64KB.
        // Inheriting sends the child's diagnostics to our stderr -- exactly
        // where an MCP stdio server's logs belong.
        //
        // readLine keeps the trailing '\n' (like fs.createReadStream's readLine,
        // spec 053) so a genuine blank line does not collapse into the "" that
        // marks true EOF. It uses takeDelimiterInclusive, which advances the
        // reader PAST the delimiter -- the exclusive variant leaves '\n'
        // buffered and would make every subsequent readLine see a zero-length
        // result (EOF), breaking multi-line conversations.
        //
        // v1 limits (documented, accepted): a single stdout line longer than the
        // 64KB reader buffer yields "" (StreamTooLong); close() blocks in wait()
        // until the child exits (no kill/timeout path); the handle is
        // single-consumer, like LumenSocket.
        try out.appendSlice(arena,
            \\pub const LumenChildProcess = struct {
            \\    child: ?std.process.Child,
            \\    io: std.Io,
            \\    alive: bool = true,
            \\    stdin_writer: std.Io.File.Writer = undefined,
            \\    stdout_reader: std.Io.File.Reader = undefined,
            \\    fn __init(io: std.Io, child: ?std.process.Child) *LumenChildProcess {
            \\        const p = __sa().create(LumenChildProcess) catch unreachable;
            \\        p.* = .{ .child = child, .io = io };
            \\        if (p.child) |*c| {
            \\            if (c.stdin) |f| {
            \\                const wbuf = __sa().alloc(u8, 65536) catch unreachable;
            \\                p.stdin_writer = f.writerStreaming(io, wbuf);
            \\            }
            \\            if (c.stdout) |f| {
            \\                const rbuf = __sa().alloc(u8, 65536) catch unreachable;
            \\                p.stdout_reader = f.reader(io, rbuf);
            \\            }
            \\        }
            \\        return p;
            \\    }
            \\    fn write(self: *LumenChildProcess, data: []const u8) void {
            \\        if (!self.alive) return;
            \\        if (self.child == null or self.child.?.stdin == null) return;
            \\        self.stdin_writer.interface.writeAll(data) catch return;
            \\        // Flush every call: a long-lived stdio peer must see the
            \\        // bytes now, same rationale as LumenSocket.write.
            \\        self.stdin_writer.interface.flush() catch {};
            \\    }
            \\    fn writeLine(self: *LumenChildProcess, data: []const u8) void {
            \\        if (!self.alive) return;
            \\        if (self.child == null or self.child.?.stdin == null) return;
            \\        self.stdin_writer.interface.writeAll(data) catch return;
            \\        self.stdin_writer.interface.writeAll("\n") catch return;
            \\        self.stdin_writer.interface.flush() catch {};
            \\    }
            \\    fn readLine(self: *LumenChildProcess) []const u8 {
            \\        if (!self.alive) return "";
            \\        if (self.child == null or self.child.?.stdout == null) return "";
            \\        const raw = self.stdout_reader.interface.takeDelimiterInclusive('\n') catch |e| blk: {
            \\            if (e != error.EndOfStream) break :blk "";
            \\            const left = self.stdout_reader.interface.buffered();
            \\            if (left.len == 0) break :blk "";
            \\            self.stdout_reader.interface.toss(left.len);
            \\            break :blk left;
            \\        };
            \\        if (raw.len == 0) return "";
            \\        return __sa().dupe(u8, raw) catch "";
            \\    }
            \\    fn close(self: *LumenChildProcess) void {
            \\        if (!self.alive) return;
            \\        self.alive = false;
            \\        if (self.child) |*c| {
            \\            if (c.stdin) |f| {
            \\                self.stdin_writer.interface.flush() catch {};
            \\                f.close(self.io);
            \\                c.stdin = null;
            \\            }
            \\            _ = c.wait(self.io) catch {};
            \\        }
            \\    }
            \\};
            \\fn __spawn(io: std.Io, alloc: std.mem.Allocator, command: []const u8, args: []const []const u8) *LumenChildProcess {
            \\    const argv = alloc.alloc([]const u8, 1 + args.len) catch return LumenChildProcess.__init(io, null);
            \\    argv[0] = command;
            \\    for (args, 0..) |a, i| argv[i + 1] = a;
            \\    const child = std.process.spawn(io, .{
            \\        .argv = argv,
            \\        .stdin = .pipe,
            \\        .stdout = .pipe,
            \\        .stderr = .inherit,
            \\    }) catch return LumenChildProcess.__init(io, null);
            \\    return LumenChildProcess.__init(io, child);
            \\}
            \\
        );
    }
    if (program.needs_assert) {
        // assert.* wraps the language's own panic mechanism, not the throw/
        // catch machinery (a static call has no access to an enclosing
        // try's throw target) -- a failed assertion crashes the program,
        // uncatchable, the same idiom as C's assert() or an uncaught Node
        // AssertionError.
        try out.appendSlice(arena,
            \\fn __assertOk(cond: bool) void {
            \\    if (!cond) @panic("AssertionError: assert.ok failed");
            \\}
            \\fn __assertEqual(a: anytype, b: anytype) void {
            \\    if (a != b) std.debug.panic("AssertionError: {any} != {any}", .{ a, b });
            \\}
            \\fn __assertStrEqual(a: []const u8, b: []const u8) void {
            \\    if (!std.mem.eql(u8, a, b)) std.debug.panic("AssertionError: \"{s}\" != \"{s}\"", .{ a, b });
            \\}
            \\
        );
    }
    if (program.needs_time_api) {
        // time.now()/monotonic() (spec 041): one clock read each, the same
        // primitive that already backs fs.mkdtempSync's uniqueness suffix.
        // Milliseconds as i64, not int: real epoch milliseconds hugely
        // exceeds a 32-bit range, so truncating the way os.totalmem() does
        // would make the result meaningless rather than an occasional
        // deviation.
        try out.appendSlice(arena,
            \\fn __timeNow(io: std.Io) i64 {
            \\    const ts = std.Io.Clock.now(.real, io);
            \\    return @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
            \\}
            \\fn __timeMonotonic(io: std.Io) i64 {
            \\    const ts = std.Io.Clock.now(.awake, io);
            \\    return @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
            \\}
            \\
        );
    }
    if (program.needs_console_stdout) {
        // console.log/info/debug (spec 048): a real stdout writer. Unlike
        // std.debug.print (which always targets stderr -- the mechanism
        // console.error/warn/trace still use directly), stdout needs the
        // __io-backed std.Io.File writer, the same pattern the compiler
        // CLI's own error reporting already uses for stderr.
        //
        // Bug found in review (spec 046's Streams work hit the same class
        // of bug earlier this session): File.writer() defaults to
        // *positional* writing (each write happens via a position that
        // resets per Writer instance, not a continuing stream position) --
        // its own doc comment says so explicitly ("Positional is more
        // threadsafe, since the global seek position is not affected").
        // Since __consoleOut creates a fresh Writer on every call, every
        // call after the first silently overwrote the previous one instead
        // of appending, when stdout was a redirected file/pipe (as the
        // conformance harness itself does) -- confirmed directly: three
        // console.log calls to a file only left the last line's content.
        // writerStreaming() is the sequential-append variant Streams
        // already established as the correct choice for a real stream like
        // stdout, not a seekable file.
        try out.appendSlice(arena,
            \\fn __consoleOut(comptime __fmt: []const u8, __args: anytype) void {
            \\    var __buf: [4096]u8 = undefined;
            \\    var __w = std.Io.File.stdout().writerStreaming(__io, &__buf);
            \\    __w.interface.print(__fmt, __args) catch return;
            \\    __w.interface.flush() catch {};
            \\}
            \\
        );
    }
}

pub fn emitOsCryptoRuntime(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), program: *const ast.Program, options: CompileOptions) CompileError!void {
    _ = options;
    if (program.needs_process_api) {
        // cwd/chdir/env go through Io-abstracted (cwd/chdir) or entry-captured
        // (env, same mechanism as __args) primitives -- none of these need
        // libc linking. platform/arch are resolved at compile time.
        try out.appendSlice(arena,
            \\fn __processCwd(io: std.Io, alloc: std.mem.Allocator) []const u8 {
            \\    var buf: [std.fs.max_path_bytes]u8 = undefined;
            \\    const n = std.process.currentPath(io, &buf) catch return "";
            \\    return alloc.dupe(u8, buf[0..n]) catch "";
            \\}
            \\fn __processChdir(io: std.Io, path: []const u8) void {
            \\    std.process.setCurrentPath(io, path) catch {};
            \\}
            \\fn __processEnv(key: []const u8) ?[]const u8 {
            \\    const v = std.process.Environ.getPosix(__environ, key) orelse return null;
            \\    return v;
            \\}
            \\fn __processPlatform() []const u8 {
            \\    return switch (@import("builtin").os.tag) {
            \\        .linux => "linux",
            \\        .macos => "darwin",
            \\        .windows => "win32",
            \\        .freebsd => "freebsd",
            \\        .openbsd => "openbsd",
            \\        else => "unknown",
            \\    };
            \\}
            \\fn __processArch() []const u8 {
            \\    return switch (@import("builtin").cpu.arch) {
            \\        .x86_64 => "x64",
            \\        .x86 => "ia32",
            \\        .aarch64 => "arm64",
            \\        .arm => "arm",
            \\        .riscv64 => "riscv64",
            \\        else => "unknown",
            \\    };
            \\}
            \\fn __processPid() i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @intCast(std.os.linux.getpid());
            \\}
            \\
        );
        // process API completion (spec 050). uptime()/hrtime() reuse the
        // same Io.Clock primitive spec 041's time.now()/time.monotonic()
        // already wired up. memoryUsage() reads /proc/self/status with the
        // same readFileAlloc primitive fs.readFileSync already uses. kill/
        // umask/getuid-family are raw Linux syscalls, no libc. version() is
        // a hardcoded marker -- see spec.md for why it isn't Node's.
        try out.appendSlice(arena,
            \\const LUMEN_VERSION: []const u8 = "0.3.1";
            \\fn __processHrtime(io: std.Io) i64 {
            \\    const ts = std.Io.Clock.now(.awake, io);
            \\    return @intCast(ts.nanoseconds);
            \\}
            \\pub const __LumenProcessMemory = struct { rss: i64, vsize: i64 };
            \\fn __processStatusField(text: []const u8, label: []const u8) i64 {
            \\    var lines = std.mem.splitScalar(u8, text, '\n');
            \\    while (lines.next()) |line| {
            \\        if (!std.mem.startsWith(u8, line, label)) continue;
            \\        const rest = std.mem.trim(u8, line[label.len..], " \t");
            \\        var it = std.mem.splitScalar(u8, rest, ' ');
            \\        const num = it.next() orelse return 0;
            \\        const kb = std.fmt.parseInt(i64, num, 10) catch return 0;
            \\        return kb * 1024;
            \\    }
            \\    return 0;
            \\}
            \\fn __processMemoryUsage(io: std.Io, alloc: std.mem.Allocator) __LumenProcessMemory {
            \\    // /proc entries report st_size == 0, which silently short-circuits
            \\    // Dir.readFileAlloc's default *positional* reader (confirmed by
            \\    // testing directly: it returns a 0-length read for this exact
            \\    // path). readerStreaming does a real sequential read loop instead
            \\    // and reads the real content correctly -- same fix fs.readFileSync
            \\    // doesn't need for ordinary files, but /proc pseudo-files do.
            \\    var file = std.Io.Dir.cwd().openFile(io, "/proc/self/status", .{}) catch return .{ .rss = 0, .vsize = 0 };
            \\    defer file.close(io);
            \\    var buf: [512]u8 = undefined;
            \\    var file_reader = file.readerStreaming(io, &buf);
            \\    const text = file_reader.interface.allocRemaining(alloc, .limited(64 * 1024)) catch return .{ .rss = 0, .vsize = 0 };
            \\    return .{
            \\        .rss = __processStatusField(text, "VmRSS:"),
            \\        .vsize = __processStatusField(text, "VmSize:"),
            \\    };
            \\}
            \\fn __processSignalFromName(name: []const u8) std.os.linux.SIG {
            \\    const stripped = if (std.mem.startsWith(u8, name, "SIG")) name[3..] else name;
            \\    return std.meta.stringToEnum(std.os.linux.SIG, stripped) orelse @enumFromInt(0);
            \\}
            \\fn __processKill(pid: i32, signal: []const u8) bool {
            \\    if (@import("builtin").os.tag != .linux) return false;
            \\    const sig = __processSignalFromName(signal);
            \\    std.posix.kill(pid, sig) catch return false;
            \\    return true;
            \\}
            \\fn __processUmaskRaw(mask: u32) u32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @truncate(std.os.linux.syscall1(.umask, @as(u64, mask)));
            \\}
            \\fn __processUmaskGet() i32 {
            \\    const old = __processUmaskRaw(0o022);
            \\    _ = __processUmaskRaw(old);
            \\    return @intCast(old);
            \\}
            \\fn __processUmaskSet(mask: i32) i32 {
            \\    return @intCast(__processUmaskRaw(@intCast(mask)));
            \\}
            \\fn __processGetuid() i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @intCast(std.os.linux.getuid());
            \\}
            \\fn __processGetgid() i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @intCast(std.os.linux.getgid());
            \\}
            \\fn __processGeteuid() i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @intCast(std.os.linux.geteuid());
            \\}
            \\fn __processGetegid() i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @intCast(std.os.linux.getegid());
            \\}
            \\
        );
    }
    if (program.needs_process_uptime) {
        // A separate block (not folded into needs_process_api above)
        // because this is the only process.* function needing code to run
        // unconditionally in main() before user code -- recording a start
        // timestamp -- which the rest of the namespace doesn't need.
        try out.appendSlice(arena,
            \\var __process_start_ns: i64 = 0;
            \\fn __processUptime() f64 {
            \\    const ts = std.Io.Clock.now(.awake, __io);
            \\    const elapsed_ns = @as(i64, @intCast(ts.nanoseconds)) - __process_start_ns;
            \\    return @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            \\}
            \\
        );
    }
    if (program.needs_os_api) {
        // Two raw Linux syscalls cover almost this whole namespace: uname()
        // (sysname/nodename/release/version/machine in one call) and
        // sysinfo() (uptime/loads/totalram/freeram in one call). No libc.
        // __osTmpdir/__osHomedir below reference __processEnv, only emitted
        // when program.needs_process_api is set -- safe because Zig only
        // semantically analyzes a function body when it's actually called,
        // and the checker sets needs_process_api whenever tmpdir/homedir
        // (the only functions here that call __processEnv) are used.
        try out.appendSlice(arena,
            \\fn __osUname() std.os.linux.utsname {
            \\    var uts: std.os.linux.utsname = std.mem.zeroes(std.os.linux.utsname);
            \\    if (@import("builtin").os.tag == .linux) _ = std.os.linux.uname(&uts);
            \\    return uts;
            \\}
            \\fn __osUnameField(comptime field: []const u8) []const u8 {
            \\    const uts = __osUname();
            \\    const s = std.mem.sliceTo(&@field(uts, field), 0);
            \\    return __alloc.dupe(u8, s) catch "";
            \\}
            \\fn __osEndianness() []const u8 {
            \\    return switch (@import("builtin").cpu.arch.endian()) {
            \\        .little => "LE",
            \\        .big => "BE",
            \\    };
            \\}
            \\fn __osTmpdir() []const u8 {
            \\    if (__processEnv("TMPDIR")) |v| return v;
            \\    if (__processEnv("TMP")) |v| return v;
            \\    if (__processEnv("TEMP")) |v| return v;
            \\    return "/tmp";
            \\}
            \\fn __osSysinfo() std.os.linux.Sysinfo {
            \\    var info: std.os.linux.Sysinfo = std.mem.zeroes(std.os.linux.Sysinfo);
            \\    if (@import("builtin").os.tag == .linux) _ = std.os.linux.sysinfo(&info);
            \\    return info;
            \\}
            \\fn __osMemBytes(total: bool) i32 {
            \\    const info = __osSysinfo();
            \\    const raw: u64 = if (total) @intCast(info.totalram) else @intCast(info.freeram);
            \\    const bytes: u64 = raw * @as(u64, @intCast(info.mem_unit));
            \\    return @truncate(@as(i64, @intCast(bytes)));
            \\}
            \\fn __osLoadavg(alloc: std.mem.Allocator) []const f64 {
            \\    const info = __osSysinfo();
            \\    const out = alloc.alloc(f64, 3) catch return &.{};
            \\    out[0] = @as(f64, @floatFromInt(info.loads[0])) / 65536.0;
            \\    out[1] = @as(f64, @floatFromInt(info.loads[1])) / 65536.0;
            \\    out[2] = @as(f64, @floatFromInt(info.loads[2])) / 65536.0;
            \\    return out;
            \\}
            \\
        );
    }
    if (program.needs_crypto_api) {
        // Pure computation throughout -- the entropy source and the hash
        // implementation are both just data manipulation, no syscalls, so
        // this works identically on the native and wasm targets.
        try out.appendSlice(arena,
            \\fn __cryptoHexEncode(alloc: std.mem.Allocator, bytes: []const u8) []const u8 {
            \\    const hex_chars = "0123456789abcdef";
            \\    const out = alloc.alloc(u8, bytes.len * 2) catch return "";
            \\    for (bytes, 0..) |b, i| {
            \\        out[i * 2] = hex_chars[b >> 4];
            \\        out[i * 2 + 1] = hex_chars[b & 0x0f];
            \\    }
            \\    return out;
            \\}
            \\fn __cryptoRandomBytes(io: std.Io, alloc: std.mem.Allocator, n: i32) []const u8 {
            \\    const count: usize = @intCast(@max(n, 0));
            \\    const buf = alloc.alloc(u8, count) catch return "";
            \\    std.Io.random(io, buf);
            \\    return __cryptoHexEncode(alloc, buf);
            \\}
            \\fn __cryptoRandomUUID(io: std.Io, alloc: std.mem.Allocator) []const u8 {
            \\    var bytes: [16]u8 = undefined;
            \\    std.Io.random(io, &bytes);
            \\    bytes[6] = (bytes[6] & 0x0f) | 0x40;
            \\    bytes[8] = (bytes[8] & 0x3f) | 0x80;
            \\    const hex = __cryptoHexEncode(alloc, &bytes);
            \\    return std.fmt.allocPrint(alloc, "{s}-{s}-{s}-{s}-{s}", .{
            \\        hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32],
            \\    }) catch "";
            \\}
            \\fn __cryptoSha256(alloc: std.mem.Allocator, data: []const u8) []const u8 {
            \\    var out: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            \\    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
            \\    return __cryptoHexEncode(alloc, &out);
            \\}
            \\
            \\fn __cryptoSha1Raw(data: []const u8) [std.crypto.hash.Sha1.digest_length]u8 {
            \\    var out: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
            \\    std.crypto.hash.Sha1.hash(data, &out, .{});
            \\    return out;
            \\}
            \\
            \\fn __cryptoSha1(alloc: std.mem.Allocator, data: []const u8) []const u8 {
            \\    const out = __cryptoSha1Raw(data);
            \\    return __cryptoHexEncode(alloc, &out);
            \\}
            \\
            \\fn __cryptoSha1Bytes(alloc: std.mem.Allocator, data: []const u8) []const u8 {
            \\    const out = __cryptoSha1Raw(data);
            \\    const buf = alloc.alloc(u8, out.len) catch unreachable;
            \\    @memcpy(buf, &out);
            \\    return buf;
            \\}
            \\
            \\fn __cryptoBase64Encode(alloc: std.mem.Allocator, data: []const u8) []const u8 {
            \\    const enc = std.base64.standard.Encoder;
            \\    const buf = alloc.alloc(u8, enc.calcSize(data.len)) catch unreachable;
            \\    return enc.encode(buf, data);
            \\}
            \\
            \\fn __cryptoBase64Decode(alloc: std.mem.Allocator, text: []const u8) []const u8 {
            \\    const dec = std.base64.standard.Decoder;
            \\    const n = dec.calcSizeForSlice(text) catch return "";
            \\    const buf = alloc.alloc(u8, n) catch unreachable;
            \\    dec.decode(buf, text) catch return "";
            \\    return buf;
            \\}
            \\
        );
    }
    if (program.needs_aead) {
        // crypto.encrypt/decrypt (spec 467): AES-256-GCM, an *authenticated*
        // cipher. Decryption verifies the tag over the whole ciphertext
        // before it hands anything back, so an envelope that was altered in
        // storage or in transit is rejected instead of decrypting to
        // plausible-looking garbage the caller would go on to use.
        try out.appendSlice(arena,
            \\const __CryptoAead = std.crypto.aead.aes_gcm.Aes256Gcm;
            \\fn __cryptoRequireKey(key: []const u8) [__CryptoAead.key_length]u8 {
            \\    // Truncating or zero-padding a wrong-length key would keep
            \\    // working while encrypting under a key nobody chose, which is
            \\    // a weak cipher that looks like a working one. Refuse instead.
            \\    // The key is the caller's own configuration, not attacker
            \\    // input, so being loud about it discloses nothing.
            \\    if (key.len != __CryptoAead.key_length) @panic("crypto key must be exactly 32 bytes");
            \\    var k: [__CryptoAead.key_length]u8 = undefined;
            \\    @memcpy(&k, key);
            \\    return k;
            \\}
            \\fn __cryptoEncrypt(io: std.Io, alloc: std.mem.Allocator, plaintext: []const u8, key: []const u8) []const u8 {
            \\    const k = __cryptoRequireKey(key);
            \\    // A fresh random nonce for every call, never derived from the
            \\    // plaintext and never reused. Two messages encrypted under one
            \\    // key with one nonce hand an attacker the XOR of the two
            \\    // plaintexts and enough to forge tags for that key: nonce reuse
            \\    // breaks GCM outright, so this is the one value that must come
            \\    // from the entropy source on every single call.
            \\    var nonce: [__CryptoAead.nonce_length]u8 = undefined;
            \\    std.Io.random(io, &nonce);
            \\    const raw = alloc.alloc(u8, nonce.len + plaintext.len + __CryptoAead.tag_length) catch return "";
            \\    @memcpy(raw[0..nonce.len], &nonce);
            \\    var tag: [__CryptoAead.tag_length]u8 = undefined;
            \\    __CryptoAead.encrypt(raw[nonce.len..][0..plaintext.len], &tag, plaintext, "", nonce, k);
            \\    @memcpy(raw[nonce.len + plaintext.len ..], &tag);
            \\    // base64 so the envelope survives a text column, a JSON string
            \\    // and an HTTP header with no further encoding step.
            \\    const enc = std.base64.standard.Encoder;
            \\    const out = alloc.alloc(u8, enc.calcSize(raw.len)) catch return "";
            \\    return enc.encode(out, raw);
            \\}
            \\fn __cryptoDecrypt(alloc: std.mem.Allocator, envelope: []const u8, key: []const u8) []const u8 {
            \\    const k = __cryptoRequireKey(key);
            \\    // Every failure below returns the same empty string: input that
            \\    // is not base64, an envelope too short to hold a nonce and a
            \\    // tag, a key that does not match, a single flipped bit. Which
            \\    // check rejected the envelope is exactly what an attacker
            \\    // submitting modified envelopes is trying to learn, so the
            \\    // caller is not told either.
            \\    const dec = std.base64.standard.Decoder;
            \\    const raw_len = dec.calcSizeForSlice(envelope) catch return "";
            \\    const raw = alloc.alloc(u8, raw_len) catch return "";
            \\    dec.decode(raw, envelope) catch return "";
            \\    if (raw.len < __CryptoAead.nonce_length + __CryptoAead.tag_length) return "";
            \\    var nonce: [__CryptoAead.nonce_length]u8 = undefined;
            \\    @memcpy(&nonce, raw[0..__CryptoAead.nonce_length]);
            \\    const ct_end = raw.len - __CryptoAead.tag_length;
            \\    var tag: [__CryptoAead.tag_length]u8 = undefined;
            \\    @memcpy(&tag, raw[ct_end..]);
            \\    const ct = raw[__CryptoAead.nonce_length..ct_end];
            \\    const out = alloc.alloc(u8, ct.len) catch return "";
            \\    __CryptoAead.decrypt(out, ct, tag, "", nonce, k) catch return "";
            \\    return out;
            \\}
            \\fn __cryptoRandomKey(io: std.Io, alloc: std.mem.Allocator) []const u8 {
            \\    const key = alloc.alloc(u8, __CryptoAead.key_length) catch return "";
            \\    std.Io.random(io, key);
            \\    return key;
            \\}
            \\
        );
    }
    if (program.needs_buffer and program.needs_crypto_api) {
        // spec 057: HMAC-SHA256, AES-256-GCM, and raw (non-hex) random
        // bytes, all Buffer in/out -- see spec.md's "Why additive, not
        // breaking" for why the three hex-string functions above are
        // untouched.
        try out.appendSlice(arena,
            \\fn __cryptoRandomBytesBuffer(io: std.Io, n: i32) *LumenBuffer {
            \\    const count: usize = @intCast(@max(n, 0));
            \\    const buf = __sa().alloc(u8, count) catch return LumenBuffer.__wrap("");
            \\    std.Io.random(io, buf);
            \\    return LumenBuffer.__wrap(buf);
            \\}
            \\fn __cryptoHmacSync(key: *LumenBuffer, data: *LumenBuffer) *LumenBuffer {
            \\    var out: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
            \\    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, data.data, key.data);
            \\    const buf = __sa().alloc(u8, out.len) catch return LumenBuffer.__wrap("");
            \\    @memcpy(buf, &out);
            \\    return LumenBuffer.__wrap(buf);
            \\}
            \\fn __cryptoEncryptSync(key: *LumenBuffer, iv: *LumenBuffer, data: *LumenBuffer) *LumenBuffer {
            \\    const Aead = std.crypto.aead.aes_gcm.Aes256Gcm;
            \\    if (key.data.len != Aead.key_length or iv.data.len != Aead.nonce_length) return LumenBuffer.__wrap("");
            \\    var k: [Aead.key_length]u8 = undefined;
            \\    @memcpy(&k, key.data);
            \\    var n: [Aead.nonce_length]u8 = undefined;
            \\    @memcpy(&n, iv.data);
            \\    const c = __sa().alloc(u8, data.data.len) catch return LumenBuffer.__wrap("");
            \\    var tag: [Aead.tag_length]u8 = undefined;
            \\    Aead.encrypt(c, &tag, data.data, "", n, k);
            \\    const combined = __sa().alloc(u8, c.len + Aead.tag_length) catch return LumenBuffer.__wrap("");
            \\    @memcpy(combined[0..c.len], c);
            \\    @memcpy(combined[c.len..], &tag);
            \\    return LumenBuffer.__wrap(combined);
            \\}
            \\fn __cryptoDecryptSync(key: *LumenBuffer, iv: *LumenBuffer, data: *LumenBuffer) *LumenBuffer {
            \\    const Aead = std.crypto.aead.aes_gcm.Aes256Gcm;
            \\    if (key.data.len != Aead.key_length or iv.data.len != Aead.nonce_length or data.data.len < Aead.tag_length) return LumenBuffer.__wrap("");
            \\    var k: [Aead.key_length]u8 = undefined;
            \\    @memcpy(&k, key.data);
            \\    var n: [Aead.nonce_length]u8 = undefined;
            \\    @memcpy(&n, iv.data);
            \\    const clen = data.data.len - Aead.tag_length;
            \\    var tag: [Aead.tag_length]u8 = undefined;
            \\    @memcpy(&tag, data.data[clen..]);
            \\    const m = __sa().alloc(u8, clen) catch return LumenBuffer.__wrap("");
            \\    Aead.decrypt(m, data.data[0..clen], tag, "", n, k) catch return LumenBuffer.__wrap("");
            \\    return LumenBuffer.__wrap(m);
            \\}
            \\fn __cryptoPbkdf2Sync(password: *LumenBuffer, salt: *LumenBuffer, iterations: i32, keylen: i32) *LumenBuffer {
            \\    if (iterations < 1 or keylen <= 0) return LumenBuffer.__wrap("");
            \\    const dk = __sa().alloc(u8, @intCast(keylen)) catch return LumenBuffer.__wrap("");
            \\    std.crypto.pwhash.pbkdf2(dk, password.data, salt.data, @intCast(iterations), std.crypto.auth.hmac.sha2.HmacSha256) catch return LumenBuffer.__wrap("");
            \\    return LumenBuffer.__wrap(dk);
            \\}
            \\fn __cryptoScryptSync(password: *LumenBuffer, salt: *LumenBuffer, keylen: i32) *LumenBuffer {
            \\    if (keylen <= 0) return LumenBuffer.__wrap("");
            \\    const dk = __sa().alloc(u8, @intCast(keylen)) catch return LumenBuffer.__wrap("");
            \\    // Node's own crypto.scrypt default cost parameters
            \\    // (N=16384, r=8, p=1) -- see spec 061's "Cost parameter
            \\    // choice" for why this is used instead of Zig's own
            \\    // `owasp`/`interactive` presets.
            \\    const params = std.crypto.pwhash.scrypt.Params{ .ln = 14, .r = 8, .p = 1 };
            \\    std.crypto.pwhash.scrypt.kdf(__sa(), dk, password.data, salt.data, params) catch return LumenBuffer.__wrap("");
            \\    return LumenBuffer.__wrap(dk);
            \\}
            \\fn __cryptoTimingSafeEqual(a: *LumenBuffer, b: *LumenBuffer) bool {
            \\    if (a.data.len != b.data.len) return false;
            \\    var acc: u8 = 0;
            \\    for (a.data, 0..) |x, i| {
            \\        acc |= x ^ b.data[i];
            \\    }
            \\    return acc == 0;
            \\}
            \\
        );
    }
    if (program.needs_streaming_crypto) {
        // crypto.createHash/createHmac (spec 060): a stateful builder over
        // one of four algorithms, chosen at runtime by string (matching
        // Node's own real `createHash('sha256')` runtime-call API -- not
        // compile-time resolved). Each algorithm is a genuinely different
        // Zig type (`std.crypto.hash.Md5`/`Sha1`/`sha2.Sha256`/`sha2.
        // Sha512`, confirmed directly against this Zig 0.16.0 toolchain's
        // lib/std/crypto/{md5,Sha1,sha2}.zig), so `LumenHash` stores them
        // in a tagged union and dispatches with `inline else` so `update`/
        // `digest` are each one method body, not four. `HmacImpl` mirrors
        // this over `std.crypto.auth.hmac.{HmacMd5,HmacSha1}`/`.sha2.
        // {HmacSha256,HmacSha512}` (confirmed against lib/std/crypto/
        // hmac.zig). An unrecognized algorithm name falls back to sha256,
        // matching Buffer.from(s, encoding)'s unrecognized-encoding
        // fallback (spec 056) rather than throwing.
        try out.appendSlice(arena,
            \\const HashImpl = union(enum) {
            \\    md5: std.crypto.hash.Md5,
            \\    sha1: std.crypto.hash.Sha1,
            \\    sha256: std.crypto.hash.sha2.Sha256,
            \\    sha512: std.crypto.hash.sha2.Sha512,
            \\};
            \\pub const LumenHash = struct {
            \\    impl: HashImpl,
            \\    fn update(self: *LumenHash, data: *LumenBuffer) *LumenHash {
            \\        switch (self.impl) {
            \\            inline else => |*h| h.update(data.data),
            \\        }
            \\        return self;
            \\    }
            \\    fn digest(self: *LumenHash) *LumenBuffer {
            \\        switch (self.impl) {
            \\            inline else => |*h| {
            \\                var out: [@TypeOf(h.*).digest_length]u8 = undefined;
            \\                h.final(&out);
            \\                const buf = __sa().alloc(u8, out.len) catch return LumenBuffer.__wrap("");
            \\                @memcpy(buf, &out);
            \\                return LumenBuffer.__wrap(buf);
            \\            },
            \\        }
            \\    }
            \\};
            \\fn __cryptoCreateHash(algorithm: []const u8) *LumenHash {
            \\    const p = __sa().create(LumenHash) catch unreachable;
            \\    if (std.mem.eql(u8, algorithm, "md5")) {
            \\        p.* = .{ .impl = .{ .md5 = std.crypto.hash.Md5.init(.{}) } };
            \\    } else if (std.mem.eql(u8, algorithm, "sha1")) {
            \\        p.* = .{ .impl = .{ .sha1 = std.crypto.hash.Sha1.init(.{}) } };
            \\    } else if (std.mem.eql(u8, algorithm, "sha512")) {
            \\        p.* = .{ .impl = .{ .sha512 = std.crypto.hash.sha2.Sha512.init(.{}) } };
            \\    } else {
            \\        p.* = .{ .impl = .{ .sha256 = std.crypto.hash.sha2.Sha256.init(.{}) } };
            \\    }
            \\    return p;
            \\}
            \\const HmacImpl = union(enum) {
            \\    md5: std.crypto.auth.hmac.HmacMd5,
            \\    sha1: std.crypto.auth.hmac.HmacSha1,
            \\    sha256: std.crypto.auth.hmac.sha2.HmacSha256,
            \\    sha512: std.crypto.auth.hmac.sha2.HmacSha512,
            \\};
            \\pub const LumenHmac = struct {
            \\    impl: HmacImpl,
            \\    fn update(self: *LumenHmac, data: *LumenBuffer) *LumenHmac {
            \\        switch (self.impl) {
            \\            inline else => |*h| h.update(data.data),
            \\        }
            \\        return self;
            \\    }
            \\    fn digest(self: *LumenHmac) *LumenBuffer {
            \\        switch (self.impl) {
            \\            inline else => |*h| {
            \\                var out: [@TypeOf(h.*).mac_length]u8 = undefined;
            \\                h.final(&out);
            \\                const buf = __sa().alloc(u8, out.len) catch return LumenBuffer.__wrap("");
            \\                @memcpy(buf, &out);
            \\                return LumenBuffer.__wrap(buf);
            \\            },
            \\        }
            \\    }
            \\};
            \\fn __cryptoCreateHmac(algorithm: []const u8, key: *LumenBuffer) *LumenHmac {
            \\    const p = __sa().create(LumenHmac) catch unreachable;
            \\    if (std.mem.eql(u8, algorithm, "md5")) {
            \\        p.* = .{ .impl = .{ .md5 = std.crypto.auth.hmac.HmacMd5.init(key.data) } };
            \\    } else if (std.mem.eql(u8, algorithm, "sha1")) {
            \\        p.* = .{ .impl = .{ .sha1 = std.crypto.auth.hmac.HmacSha1.init(key.data) } };
            \\    } else if (std.mem.eql(u8, algorithm, "sha512")) {
            \\        p.* = .{ .impl = .{ .sha512 = std.crypto.auth.hmac.sha2.HmacSha512.init(key.data) } };
            \\    } else {
            \\        p.* = .{ .impl = .{ .sha256 = std.crypto.auth.hmac.sha2.HmacSha256.init(key.data) } };
            \\    }
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_zlib_api) {
        // std.compress.flate.Container's raw/gzip/zlib variants are handled
        // internally by Compress/Decompress (header/footer framing, CRC32/
        // Adler32 checksums) -- verified directly against this Zig
        // version's lib/std/compress/flate*.zig rather than assumed, since
        // this API has churned across Zig versions. Compress needs an
        // output writer with > 8 bytes of starting capacity (an internal
        // assert), hence initCapacity rather than a bare .init. Both
        // directions need a caller-owned scratch window of
        // flate.max_window_len (64 KiB) -- heap-allocated via __alloc
        // rather than put on the stack, so this doesn't blow up every call
        // site's frame size.
        try out.appendSlice(arena,
            \\fn __zlibCompress(alloc: std.mem.Allocator, container: std.compress.flate.Container, data: []const u8) []const u8 {
            \\    var allocating = std.Io.Writer.Allocating.initCapacity(alloc, data.len + 64) catch return "";
            \\    defer allocating.deinit();
            \\    const window = alloc.alloc(u8, std.compress.flate.max_window_len) catch return "";
            \\    defer alloc.free(window);
            \\    var c = std.compress.flate.Compress.init(&allocating.writer, window, container, .default) catch return "";
            \\    c.writer.writeAll(data) catch return "";
            \\    c.finish() catch return "";
            \\    return allocating.toOwnedSlice() catch "";
            \\}
            \\fn __zlibDecompress(alloc: std.mem.Allocator, container: std.compress.flate.Container, data: []const u8) []const u8 {
            \\    var reader = std.Io.Reader.fixed(data);
            \\    const window = alloc.alloc(u8, std.compress.flate.max_window_len) catch return "";
            \\    defer alloc.free(window);
            \\    var d = std.compress.flate.Decompress.init(&reader, container, window);
            \\    return d.reader.allocRemaining(alloc, .unlimited) catch return "";
            \\}
            \\
        );
    }
    if (program.needs_httpget) {
        // A real std.http one-shot GET, wrapped to a Lumen-friendly `i64` (status code, or -1 on error).
        try out.appendSlice(arena,
            \\fn __httpGet(io: std.Io, alloc: std.mem.Allocator, url: []const u8) i64 {
            \\    var client: std.http.Client = .{ .allocator = alloc, .io = io };
            \\    defer client.deinit();
            \\    client.ca_bundle.rescan(alloc, io, std.Io.Clock.now(.real, io)) catch return -1;
            \\    const res = client.fetch(.{ .location = .{ .url = url } }) catch return -1;
            \\    return @intFromEnum(res.status);
            \\}
            \\
        );
    }
    if (program.needs_serve) {
        // A real (blocking) HTTP server on std.Io.net — returns the same body to every request.
        try out.appendSlice(arena,
            \\fn __serve(io: std.Io, alloc: std.mem.Allocator, port: i64, body: []const u8) noreturn {
            \\    _ = alloc;
            \\    const addr = std.Io.net.IpAddress.parse("0.0.0.0", @intCast(port)) catch std.process.exit(1);
            \\    var server = addr.listen(io, .{ .reuse_address = true }) catch std.process.exit(1);
            \\    var hbuf: [256]u8 = undefined;
            \\    const head = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch std.process.exit(1);
            \\    while (true) {
            \\        const stream = server.accept(io) catch continue;
            \\        var wbuf: [2048]u8 = undefined;
            \\        var w = stream.writer(io, &wbuf);
            \\        w.interface.writeAll(head) catch {};
            \\        w.interface.writeAll(body) catch {};
            \\        w.interface.flush() catch {};
            \\        stream.close(io);
            \\    }
            \\}
            \\
        );
    }
}

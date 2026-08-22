//! Runtime prelude codegen for the filesystem surface: async fs (libxev),
//! sync `fs.*Sync` wrappers, fd APIs, `fs.watch`, file streams, and the
//! worker-thread runtime.
//!
//! Extracted from `lumen_compiler.zig` purely by size: each `emit*` function
//! appends the same gated runtime-prelude Zig source blocks it always did,
//! in the same order, driven by the `program.needs_*` flags the checker set.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const CompileOptions = @import("lumen_emit.zig").CompileOptions;
const CompileError = @import("lumen_diag.zig").CompileError;

pub fn emitFsRuntime(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), program: *const ast.Program, options: CompileOptions, decls: []const u8) CompileError!void {
    // Kept in the signature although nothing here reads it any more: the fs
    // runtime used to emit two shapes of every call depending on
    // `runtime_locations`, and it now emits one. The caller passes what it
    // passes to every other runtime emitter, and the next option this file
    // needs will find it already here.
    _ = options;
    if (program.needs_async_read_file) {
        // `fs.readFile` -- true async read on libxev's io_uring backend (no
        // thread pool, unlike fs.readFileSync's synchronous std.Io.Dir call or
        // Node's libuv-backed fs.readFile, which is always thread-pool-based).
        // The open is synchronous (a fast metadata-only syscall); the read loop
        // (pread at increasing offsets into a fixed chunk, accumulating into a
        // growable buffer until a zero-length read) is fully async, resolving
        // the returned Promise<string> on completion.
        try out.appendSlice(arena,
            \\const __ReadFileChunk = 65536;
            \\const __ReadFileState = struct {
            \\    file: xev.File,
            \\    promise: *LumenPromise([]const u8),
            \\    buf: std.ArrayListUnmanaged(u8) = .empty,
            \\    chunk: [__ReadFileChunk]u8 = undefined,
            \\    offset: u64 = 0,
            \\    completion: xev.Completion = undefined,
            \\    close_completion: xev.Completion = undefined,
            \\    fn onRead(ud: ?*__ReadFileState, loop: *xev.Loop, c: *xev.Completion, file: xev.File, rb: xev.ReadBuffer, result: xev.ReadError!usize) xev.CallbackAction {
            \\        _ = loop;
            \\        _ = c;
            \\        _ = rb;
            \\        const st = ud.?;
            \\        const n = result catch 0;
            \\        if (n == 0) {
            \\            st.promise.resolve(st.buf.toOwnedSlice(__alloc) catch "");
            \\            file.close(&__xev_loop, &st.close_completion, void, null, struct {
            \\                fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.File, _: xev.CloseError!void) xev.CallbackAction {
            \\                    return .disarm;
            \\                }
            \\            }.cb);
            \\            return .disarm;
            \\        }
            \\        st.buf.appendSlice(__alloc, st.chunk[0..n]) catch {};
            \\        st.offset += n;
            \\        st.file.pread(&__xev_loop, &st.completion, .{ .slice = &st.chunk }, st.offset, __ReadFileState, st, onRead);
            \\        return .disarm;
            \\    }
            \\};
            \\fn __readFileAsync(path: []const u8) *LumenPromise([]const u8) {
            \\    const p = LumenPromise([]const u8).create();
            \\    const sync_file = std.Io.Dir.cwd().openFile(__io, path, .{ .mode = .read_only }) catch {
            \\        p.resolve("");
            \\        return p;
            \\    };
            \\    const xf = xev.File.init(sync_file) catch {
            \\        p.resolve("");
            \\        return p;
            \\    };
            \\    const st = __alloc.create(__ReadFileState) catch unreachable;
            \\    st.* = .{ .file = xf, .promise = p };
            \\    st.file.pread(&__xev_loop, &st.completion, .{ .slice = &st.chunk }, 0, __ReadFileState, st, __ReadFileState.onRead);
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_async_write_file) {
        // `fs.writeFile` -- the async counterpart to `fs.readFile`. The open
        // (create/truncate) is a fast synchronous metadata call; the write
        // loop (pwrite at increasing offsets, looping on a short write) is
        // fully async, resolving the returned Promise<void> on completion.
        try out.appendSlice(arena,
            \\const __WriteFileState = struct {
            \\    file: xev.File,
            \\    promise: *LumenPromise(void),
            \\    data: []const u8,
            \\    // Where in the file writing starts -- 0 for writeFile, the
            \\    // pre-write file size for appendFile. `offset` below always
            \\    // tracks bytes of `data` written so far, relative to this.
            \\    base_offset: u64 = 0,
            \\    offset: u64 = 0,
            \\    completion: xev.Completion = undefined,
            \\    close_completion: xev.Completion = undefined,
            \\    fn onWrite(ud: ?*__WriteFileState, loop: *xev.Loop, c: *xev.Completion, file: xev.File, wb: xev.WriteBuffer, result: xev.WriteError!usize) xev.CallbackAction {
            \\        _ = loop;
            \\        _ = c;
            \\        _ = wb;
            \\        const st = ud.?;
            \\        const n = result catch 0;
            \\        st.offset += n;
            \\        if (n == 0 or st.offset >= st.data.len) {
            \\            st.promise.resolve({});
            \\            file.close(&__xev_loop, &st.close_completion, void, null, struct {
            \\                fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.File, _: xev.CloseError!void) xev.CallbackAction {
            \\                    return .disarm;
            \\                }
            \\            }.cb);
            \\            return .disarm;
            \\        }
            \\        st.file.pwrite(&__xev_loop, &st.completion, .{ .slice = st.data[st.offset..] }, st.base_offset + st.offset, __WriteFileState, st, onWrite);
            \\        return .disarm;
            \\    }
            \\};
            \\fn __writeFileStart(p: *LumenPromise(void), sync_file: std.Io.File, data: []const u8, base_offset: u64) void {
            \\    const xf = xev.File.init(sync_file) catch {
            \\        p.resolve({});
            \\        return;
            \\    };
            \\    if (data.len == 0) {
            \\        p.resolve({});
            \\        xf.close(&__xev_loop, &(__alloc.create(xev.Completion) catch unreachable).*, void, null, struct {
            \\            fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.File, _: xev.CloseError!void) xev.CallbackAction {
            \\                return .disarm;
            \\            }
            \\        }.cb);
            \\        return;
            \\    }
            \\    const st = __alloc.create(__WriteFileState) catch unreachable;
            \\    st.* = .{ .file = xf, .promise = p, .data = data, .base_offset = base_offset };
            \\    st.file.pwrite(&__xev_loop, &st.completion, .{ .slice = data }, base_offset, __WriteFileState, st, __WriteFileState.onWrite);
            \\}
            \\fn __writeFileAsync(path: []const u8, data: []const u8) *LumenPromise(void) {
            \\    const p = LumenPromise(void).create();
            \\    const sync_file = std.Io.Dir.cwd().createFile(__io, path, .{}) catch {
            \\        p.resolve({});
            \\        return p;
            \\    };
            \\    __writeFileStart(p, sync_file, data, 0);
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_async_append_file) {
        // `fs.appendFile` -- same async write loop as `fs.writeFile`, just
        // starting past the file's existing content instead of at 0. There is
        // no seek/append-mode primitive to lean on here, so the existing size
        // is read with one fast synchronous stat before the async loop starts.
        try out.appendSlice(arena,
            \\fn __appendFileAsync(path: []const u8, data: []const u8) *LumenPromise(void) {
            \\    const p = LumenPromise(void).create();
            \\    const existing_size: u64 = if (std.Io.Dir.cwd().statFile(__io, path, .{}) catch null) |st| st.size else 0;
            \\    const sync_file = std.Io.Dir.cwd().createFile(__io, path, .{ .truncate = false }) catch {
            \\        p.resolve({});
            \\        return p;
            \\    };
            \\    __writeFileStart(p, sync_file, data, existing_size);
            \\    return p;
            \\}
            \\
        );
    }
    try out.appendSlice(arena, decls);

    if (program.needs_read_file_sync) {
        // A missing or unreadable file raises a catchable Lumen exception
        // (spec 253) instead of silently reading as "".
        //
        // NOT gated on `runtime_locations`. That option decides whether an
        // error carries a file and line — how readable the message is — and
        // it must not decide WHETHER a failure is reported. Gated, the same
        // program read "" under --release-fast and threw under --debug, which
        // is the worst kind of difference between build modes: the fast one
        // is what ships. The comment above __lumen_throwing records the last
        // time this conflation bit.
        // readFileAlloc (used here previously) opens the file and calls
        // File.Reader's allocRemainingAlignedSentinel, which stats the file
        // once for its size and then, on the streaming/positional read
        // paths (Io/Reader.zig, File/Reader.zig), computes `size - pos`
        // to bound each subsequent read against that cached size. If the
        // file shrinks between that stat and a later read of it -- which is
        // exactly what fs.appendFileSync used to do to every file it
        // touched (#26), and which any other writer truncating the file
        // can still do -- `pos` can end up bigger than the stale `size` and
        // that subtraction wraps. Zig's runtime safety check turns the
        // wraparound into a trap: not a Zig error, not something `catch`
        // sees, the process just aborts. A Lumen try/catch around
        // fs.readFileSync cannot protect against this (#25).
        //
        // Reading with a manual readStreaming loop instead avoids the bug
        // by construction: it never consults or caches a file size, so
        // there is no `size - pos` to wrap. Each call just reports how many
        // bytes the kernel actually handed back; a file that shrank mid-read
        // yields a short read or an early end-of-file, not a trap.
        try out.appendSlice(arena,
            \\fn __readFileSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) error{LumenThrow}![]const u8 {
            \\    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |e| {
            \\        __lumen_err_msg = std.fmt.allocPrint(alloc, "cannot read '{s}': {s}", .{ path, @errorName(e) }) catch "cannot read file";
            \\        __lumen_throwing = true;
            \\        return error.LumenThrow;
            \\    };
            \\    defer file.close(io);
            \\    const read_limit: usize = 16 * 1024 * 1024;
            \\    var list: std.ArrayListUnmanaged(u8) = .empty;
            \\    var chunk: [64 * 1024]u8 = undefined;
            \\    while (true) {
            \\        // readStreaming signals real end-of-file as
            \\        // error.EndOfStream, not a 0-length read (confirmed by
            \\        // reading fileReadStreamingPosix: "if (rc == 0) return
            \\        // error.EndOfStream"), so that is the normal, expected
            \\        // way this loop ends -- not a failure to report.
            \\        const n = file.readStreaming(io, &.{chunk[0..]}) catch |e| switch (e) {
            \\            error.EndOfStream => break,
            \\            else => {
            \\                __lumen_err_msg = std.fmt.allocPrint(alloc, "cannot read '{s}': {s}", .{ path, @errorName(e) }) catch "cannot read file";
            \\                __lumen_throwing = true;
            \\                return error.LumenThrow;
            \\            },
            \\        };
            \\        if (n == 0) break;
            \\        if (list.items.len + n > read_limit) {
            \\            __lumen_err_msg = std.fmt.allocPrint(alloc, "cannot read '{s}': StreamTooLong", .{path}) catch "cannot read file";
            \\            __lumen_throwing = true;
            \\            return error.LumenThrow;
            \\        }
            \\        list.appendSlice(alloc, chunk[0..n]) catch {
            \\            __lumen_err_msg = "cannot read: out of memory";
            \\            __lumen_throwing = true;
            \\            return error.LumenThrow;
            \\        };
            \\    }
            \\    return list.toOwnedSlice(alloc) catch {
            \\        __lumen_err_msg = "cannot read: out of memory";
            \\        __lumen_throwing = true;
            \\        return error.LumenThrow;
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_exists_sync) {
        try out.appendSlice(arena,
            \\fn __existsSync(io: std.Io, path: []const u8) bool {
            \\    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
            \\    return true;
            \\}
            \\
        );
    }
    if (program.needs_realpath_sync) {
        // fs.realpathSync (spec 031 revisited): earlier notes assumed this
        // was blocked ("only a raw libc binding exists, not wrapped by the
        // runtime's I/O layer"), but that turned out to be stale -- this
        // Zig version's std.Io.Dir has a real, working realPathFileAlloc
        // (dispatching to a genuine per-OS implementation, not a stub;
        // confirmed by reading the Io.Threaded backend directly). Falls
        // back to returning path unchanged on error (nonexistent path,
        // permissions, ...), the same "fallback, don't crash" shape every
        // other fs function uses.
        try out.appendSlice(arena,
            \\fn __realpathSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) []const u8 {
            \\    return std.Io.Dir.cwd().realPathFileAlloc(io, path, alloc) catch (alloc.dupe(u8, path) catch path);
            \\}
            \\
        );
    }
    if (program.needs_write_file_sync) {
        // Always throwing, for the reason on __readFileSync above: a write
        // that cannot happen is a fact about the program, not a detail of the
        // build. Silently, a --release-fast binary wrote nothing into a
        // directory that did not exist and carried on.
        try out.appendSlice(arena,
            \\fn __writeFileSync(io: std.Io, path: []const u8, data: []const u8) error{LumenThrow}!void {
            \\    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |e| {
            \\        __lumen_err_msg = std.fmt.allocPrint(__sa(), "cannot write '{s}': {s}", .{ path, @errorName(e) }) catch "cannot write file";
            \\        __lumen_throwing = true;
            \\        return error.LumenThrow;
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_append_file_sync) {
        // No direct append API on this std.Io.Dir; read the existing content (if
        // any), concatenate, and rewrite. Fine for sync, single-writer use.
        try out.appendSlice(arena,
            \\fn __appendFileSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8, data: []const u8) error{LumenThrow}!void {
            \\    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch "";
            \\    const combined = std.mem.concat(alloc, u8, &.{ existing, data }) catch {
            \\        __lumen_err_msg = "cannot append: out of memory";
            \\        __lumen_throwing = true;
            \\        return error.LumenThrow;
            \\    };
            \\    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = combined }) catch |e| {
            \\        __lumen_err_msg = std.fmt.allocPrint(alloc, "cannot append to '{s}': {s}", .{ path, @errorName(e) }) catch "cannot append to file";
            \\        __lumen_throwing = true;
            \\        return error.LumenThrow;
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_mkdir_sync) {
        // A directory that could not be made is reported, never swallowed.
        // The silence here was the expensive one: mkdirSync makes ONE
        // directory, so a missing parent failed, said nothing, and the next
        // write into that path failed differently somewhere else entirely.
        // AlreadyExists is not a failure — asking for a directory that is
        // there is a program getting what it wanted.
        try out.appendSlice(arena,
            \\fn __mkdirSync(io: std.Io, path: []const u8, recursive: bool) error{LumenThrow}!void {
            \\    if (recursive) {
            \\        std.Io.Dir.cwd().createDirPath(io, path) catch |e| {
            \\            __lumen_err_msg = std.fmt.allocPrint(__sa(), "cannot make '{s}': {s}", .{ path, @errorName(e) }) catch "cannot make directory";
            \\            __lumen_throwing = true;
            \\            return error.LumenThrow;
            \\        };
            \\    } else {
            \\        std.Io.Dir.cwd().createDir(io, path, std.Io.File.Permissions.default_dir) catch |e| {
            \\            if (e == error.PathAlreadyExists) return;
            \\            __lumen_err_msg = std.fmt.allocPrint(__sa(), "cannot make '{s}': {s}", .{ path, @errorName(e) }) catch "cannot make directory";
            \\            __lumen_throwing = true;
            \\            return error.LumenThrow;
            \\        };
            \\    }
            \\}
            \\
        );
    }
    if (program.needs_unlink_sync) {
        try out.appendSlice(arena,
            \\fn __unlinkSync(io: std.Io, path: []const u8) error{LumenThrow}!void {
            \\    std.Io.Dir.cwd().deleteFile(io, path) catch |e| {
            \\        __lumen_err_msg = std.fmt.allocPrint(__sa(), "cannot delete '{s}': {s}", .{ path, @errorName(e) }) catch "cannot delete file";
            \\        __lumen_throwing = true;
            \\        return error.LumenThrow;
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_rename_sync) {
        try out.appendSlice(arena,
            \\fn __renameSync(io: std.Io, old_path: []const u8, new_path: []const u8) error{LumenThrow}!void {
            \\    std.Io.Dir.rename(std.Io.Dir.cwd(), old_path, std.Io.Dir.cwd(), new_path, io) catch |e| {
            \\        __lumen_err_msg = std.fmt.allocPrint(__sa(), "cannot rename '{s}' to '{s}': {s}", .{ old_path, new_path, @errorName(e) }) catch "cannot rename";
            \\        __lumen_throwing = true;
            \\        return error.LumenThrow;
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_copy_file_sync) {
        try out.appendSlice(arena,
            \\fn __copyFileSync(io: std.Io, src_path: []const u8, dest_path: []const u8) error{LumenThrow}!void {
            \\    std.Io.Dir.copyFile(std.Io.Dir.cwd(), src_path, std.Io.Dir.cwd(), dest_path, io, .{}) catch |e| {
            \\        __lumen_err_msg = std.fmt.allocPrint(__sa(), "cannot copy '{s}' to '{s}': {s}", .{ src_path, dest_path, @errorName(e) }) catch "cannot copy";
            \\        __lumen_throwing = true;
            \\        return error.LumenThrow;
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_cp_sync) {
        // Composed from the same primitives as copyFileSync/mkdirSync/iterate:
        // if `src_path` opens as an iterable directory, recurse into it (only
        // when `recursive` is true); otherwise treat it as a single file.
        try out.appendSlice(arena,
            \\fn __cpSync(io: std.Io, alloc: std.mem.Allocator, src_path: []const u8, dest_path: []const u8, recursive: bool) void {
            \\    if (recursive) {
            \\        if (std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true })) |src_dir_const| {
            \\            var src_dir = src_dir_const;
            \\            defer src_dir.close(io);
            \\            std.Io.Dir.cwd().createDirPath(io, dest_path) catch {};
            \\            var it = src_dir.iterate();
            \\            while (it.next(io) catch null) |entry| {
            \\                const sub_src = std.fmt.allocPrint(alloc, "{s}/{s}", .{ src_path, entry.name }) catch continue;
            \\                const sub_dest = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_path, entry.name }) catch continue;
            \\                __cpSync(io, alloc, sub_src, sub_dest, true);
            \\            }
            \\            return;
            \\        } else |_| {}
            \\    }
            \\    std.Io.Dir.copyFile(std.Io.Dir.cwd(), src_path, std.Io.Dir.cwd(), dest_path, io, .{}) catch {};
            \\}
            \\
        );
    }
    if (program.needs_mkdtemp_sync) {
        // Not Node's mkdtempSync exactly: the suffix is a timestamp mixed with a
        // per-process counter, not cryptographic randomness (no clear
        // std.crypto.random source in this Zig version) -- adequate for a unique
        // scratch directory name, not for anything security-sensitive.
        try out.appendSlice(arena,
            \\var __mkdtemp_counter: u64 = 0;
            \\fn __mkdtempSync(io: std.Io, alloc: std.mem.Allocator, prefix: []const u8) []const u8 {
            \\    const ts = std.Io.Clock.now(.real, io).nanoseconds;
            \\    __mkdtemp_counter +%= 1;
            \\    const mixed: u32 = @as(u32, @truncate(@as(u96, @bitCast(ts)))) ^ @as(u32, @truncate(__mkdtemp_counter *% 2654435761));
            \\    const path = std.fmt.allocPrint(alloc, "{s}{x:0>8}", .{ prefix, mixed }) catch return "";
            \\    std.Io.Dir.cwd().createDir(io, path, std.Io.File.Permissions.default_dir) catch return "";
            \\    return path;
            \\}
            \\
        );
    }
    if (program.needs_stat_sync) {
        // Backs the synthetic `__LumenStat` record type the checker registers
        // for fs.statSync (lumen_check_stdlib.zig): isFile/isDirectory are plain
        // bool fields here, not methods, since builtins can't have methods yet.
        try out.appendSlice(arena,
            \\pub const __LumenStat = struct { size: i32, isFile: bool, isDirectory: bool, mtimeMs: i32 };
            \\fn __statSync(io: std.Io, path: []const u8) __LumenStat {
            \\    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .size = 0, .isFile = false, .isDirectory = false, .mtimeMs = 0 };
            \\    return .{
            \\        .size = @truncate(@as(i64, @intCast(st.size))),
            \\        .isFile = st.kind == .file,
            \\        .isDirectory = st.kind == .directory,
            \\        .mtimeMs = @truncate(@divTrunc(@as(i96, st.mtime.nanoseconds), 1_000_000)),
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_thread_pool_fs) {
        // Shared plumbing for async fs beyond readFile/writeFile/appendFile
        // (spec 047): those three are true async on libxev's io_uring
        // backend (no thread involved), but libxev's OperationType union has
        // no unlink/mkdir/rmdir/stat op on any backend (checked directly),
        // so those run a real ThreadPool.Task on a worker thread instead --
        // the same shape Node's own libuv uses for most of its async fs, and
        // the same mechanism libxev's own kqueue backend already relies on
        // internally for its file I/O (kqueue has no native completion-based
        // filesystem I/O either). One shared ThreadPool + one shared
        // xev.Async bridge per program, not one per call.
        //
        // LumenPromise.resolve() is a plain, non-atomic field write, and
        // LumenLoop.driveUntil/.drain poll it from the main thread while
        // pumping __xev_loop.run() -- calling .resolve() directly from a
        // worker thread would race that poll. So workers never resolve a
        // promise themselves: they push a completion record onto this
        // mutex-protected queue and wake the loop via xev.Async.notify();
        // only the main-thread wake-up callback below actually calls
        // .resolve(), keeping LumenPromise itself completely unchanged.
        try out.appendSlice(arena,
            \\const __FsDone = struct { ctx: *anyopaque, finish: *const fn (*anyopaque) void };
            \\var __fs_pool: xev.ThreadPool = undefined;
            \\var __fs_async: xev.Async = undefined;
            \\var __fs_async_c: xev.Completion = undefined;
            \\var __fs_done_mutex: std.Io.Mutex = .init;
            \\var __fs_done_queue: std.ArrayListUnmanaged(__FsDone) = .empty;
            \\fn __fsThreadPoolInit() void {
            \\    __fs_pool = xev.ThreadPool.init(.{});
            \\    __fs_async = xev.Async.init() catch unreachable;
            \\    __fs_async.wait(&__xev_loop, &__fs_async_c, void, null, __fsOnWake);
            \\}
            \\fn __fsOnWake(_: ?*void, _: *xev.Loop, _: *xev.Completion, r: xev.Async.WaitError!void) xev.CallbackAction {
            \\    _ = r catch {};
            \\    __fs_done_mutex.lock(__io) catch unreachable;
            \\    const items = __fs_done_queue.toOwnedSlice(__alloc) catch &.{};
            \\    __fs_done_mutex.unlock(__io);
            \\    for (items) |it| it.finish(it.ctx);
            \\    return .rearm;
            \\}
            \\fn __fsPushDone(ctx: *anyopaque, finish: *const fn (*anyopaque) void) void {
            \\    __fs_done_mutex.lock(__io) catch unreachable;
            \\    __fs_done_queue.append(__alloc, .{ .ctx = ctx, .finish = finish }) catch {};
            \\    __fs_done_mutex.unlock(__io);
            \\    __fs_async.notify() catch {};
            \\}
            \\
        );
    }
    if (program.needs_async_unlink) {
        try out.appendSlice(arena,
            \\const __UnlinkState = struct {
            \\    task: xev.ThreadPool.Task = .{ .callback = work },
            \\    path: []const u8,
            \\    promise: *LumenPromise(void),
            \\    fn work(t: *xev.ThreadPool.Task) void {
            \\        const __gc_fresh = __gcRegisterThread();
            \\        defer __gcUnregisterThread(__gc_fresh);
            \\        const self: *__UnlinkState = @fieldParentPtr("task", t);
            \\        std.Io.Dir.cwd().deleteFile(__io, self.path) catch {};
            \\        __fsPushDone(self, finish);
            \\    }
            \\    fn finish(ctx: *anyopaque) void {
            \\        const self: *__UnlinkState = @ptrCast(@alignCast(ctx));
            \\        self.promise.resolve({});
            \\    }
            \\};
            \\fn __unlinkAsync(path: []const u8) *LumenPromise(void) {
            \\    const p = LumenPromise(void).create();
            \\    const st = __alloc.create(__UnlinkState) catch unreachable;
            \\    st.* = .{ .path = path, .promise = p };
            \\    __fs_pool.schedule(xev.ThreadPool.Batch.from(&st.task));
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_async_mkdir) {
        try out.appendSlice(arena,
            \\const __MkdirState = struct {
            \\    task: xev.ThreadPool.Task = .{ .callback = work },
            \\    path: []const u8,
            \\    promise: *LumenPromise(void),
            \\    fn work(t: *xev.ThreadPool.Task) void {
            \\        const __gc_fresh = __gcRegisterThread();
            \\        defer __gcUnregisterThread(__gc_fresh);
            \\        const self: *__MkdirState = @fieldParentPtr("task", t);
            \\        std.Io.Dir.cwd().createDir(__io, self.path, std.Io.File.Permissions.default_dir) catch {};
            \\        __fsPushDone(self, finish);
            \\    }
            \\    fn finish(ctx: *anyopaque) void {
            \\        const self: *__MkdirState = @ptrCast(@alignCast(ctx));
            \\        self.promise.resolve({});
            \\    }
            \\};
            \\fn __mkdirAsync(path: []const u8) *LumenPromise(void) {
            \\    const p = LumenPromise(void).create();
            \\    const st = __alloc.create(__MkdirState) catch unreachable;
            \\    st.* = .{ .path = path, .promise = p };
            \\    __fs_pool.schedule(xev.ThreadPool.Batch.from(&st.task));
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_async_rmdir) {
        try out.appendSlice(arena,
            \\const __RmdirState = struct {
            \\    task: xev.ThreadPool.Task = .{ .callback = work },
            \\    path: []const u8,
            \\    promise: *LumenPromise(void),
            \\    fn work(t: *xev.ThreadPool.Task) void {
            \\        const __gc_fresh = __gcRegisterThread();
            \\        defer __gcUnregisterThread(__gc_fresh);
            \\        const self: *__RmdirState = @fieldParentPtr("task", t);
            \\        std.Io.Dir.cwd().deleteDir(__io, self.path) catch {};
            \\        __fsPushDone(self, finish);
            \\    }
            \\    fn finish(ctx: *anyopaque) void {
            \\        const self: *__RmdirState = @ptrCast(@alignCast(ctx));
            \\        self.promise.resolve({});
            \\    }
            \\};
            \\fn __rmdirAsync(path: []const u8) *LumenPromise(void) {
            \\    const p = LumenPromise(void).create();
            \\    const st = __alloc.create(__RmdirState) catch unreachable;
            \\    st.* = .{ .path = path, .promise = p };
            \\    __fs_pool.schedule(xev.ThreadPool.Batch.from(&st.task));
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_async_stat) {
        try out.appendSlice(arena,
            \\const __StatState = struct {
            \\    task: xev.ThreadPool.Task = .{ .callback = work },
            \\    path: []const u8,
            \\    result: __LumenStat = undefined,
            \\    promise: *LumenPromise(__LumenStat),
            \\    fn work(t: *xev.ThreadPool.Task) void {
            \\        const __gc_fresh = __gcRegisterThread();
            \\        defer __gcUnregisterThread(__gc_fresh);
            \\        const self: *__StatState = @fieldParentPtr("task", t);
            \\        self.result = __statSync(__io, self.path);
            \\        __fsPushDone(self, finish);
            \\    }
            \\    fn finish(ctx: *anyopaque) void {
            \\        const self: *__StatState = @ptrCast(@alignCast(ctx));
            \\        self.promise.resolve(self.result);
            \\    }
            \\};
            \\fn __statAsync(path: []const u8) *LumenPromise(__LumenStat) {
            \\    const p = LumenPromise(__LumenStat).create();
            \\    const st = __alloc.create(__StatState) catch unreachable;
            \\    st.* = .{ .path = path, .promise = p };
            \\    __fs_pool.schedule(xev.ThreadPool.Batch.from(&st.task));
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_worker) {
        // Worker.run(fn) -> Promise<T> (spec 059). Deliberately a bare
        // std.Thread.spawn per call, not the shared xev.ThreadPool spec 047
        // uses for fs: that pool is a fixed, CPU-count-sized set of workers
        // meant for many small, quick blocking syscalls, where queuing is
        // the right trade-off. A Worker models Node's own "one Worker == one
        // real OS thread" CPU-bound-parallelism primitive -- queuing a
        // CPU-bound Worker behind unrelated fs/http pool work would be a
        // real semantic mismatch with what the caller asked for, not just a
        // performance nuance. Confirmed against this project's vendored Zig
        // 0.16.0 `lib/std/Thread.zig` before writing this: `Thread.spawn(config,
        // comptime function, args) SpawnError!Thread` and `Thread.detach(self)
        // void` are exactly what's needed; no join is required since nothing
        // downstream waits on the OS thread itself, only on the Promise.
        //
        // Result handback reuses spec 047's exact worker-notifies-main shape:
        // LumenPromise.resolve() is a plain, non-atomic field write raced
        // against the main thread's await_/driveUntil poll if called from a
        // worker thread directly, so the worker thread never calls it -- it
        // pushes a completion record onto this dedicated, mutex-protected
        // queue and wakes a dedicated xev.Async; only the main-thread wake-up
        // callback below ever calls .resolve(). LumenPromise itself needs no
        // changes. This queue/Async pair is independent of fs's own
        // __fs_done_queue/__fs_async (Worker doesn't require fs to be used).
        try out.appendSlice(arena,
            \\const __WorkerDone = struct { ctx: *anyopaque, finish: *const fn (*anyopaque) void };
            \\var __worker_async: xev.Async = undefined;
            \\var __worker_async_c: xev.Completion = undefined;
            \\var __worker_done_mutex: std.Io.Mutex = .init;
            \\var __worker_done_queue: std.ArrayListUnmanaged(__WorkerDone) = .empty;
            \\fn __workerInit() void {
            \\    __worker_async = xev.Async.init() catch unreachable;
            \\    __worker_async.wait(&__xev_loop, &__worker_async_c, void, null, __workerOnWake);
            \\}
            \\fn __workerOnWake(_: ?*void, _: *xev.Loop, _: *xev.Completion, r: xev.Async.WaitError!void) xev.CallbackAction {
            \\    _ = r catch {};
            \\    __worker_done_mutex.lock(__io) catch unreachable;
            \\    const items = __worker_done_queue.toOwnedSlice(__alloc) catch &.{};
            \\    __worker_done_mutex.unlock(__io);
            \\    for (items) |it| it.finish(it.ctx);
            \\    return .rearm;
            \\}
            \\fn __workerPushDone(ctx: *anyopaque, finish: *const fn (*anyopaque) void) void {
            \\    __worker_done_mutex.lock(__io) catch unreachable;
            \\    __worker_done_queue.append(__alloc, .{ .ctx = ctx, .finish = finish }) catch {};
            \\    __worker_done_mutex.unlock(__io);
            \\    __worker_async.notify() catch {};
            \\}
            \\fn __workerRun(comptime T: type, f: anytype) *LumenPromise(T) {
            \\    const Cb = @TypeOf(f);
            \\    const State = struct {
            \\        f: Cb,
            \\        promise: *LumenPromise(T),
            \\        result: T = undefined,
            \\        fn threadMain(self: *@This()) void {
            \\            const __gc_fresh = __gcRegisterThread();
            \\            defer __gcUnregisterThread(__gc_fresh);
            \\            self.result = self.f.call(self.f.ctx);
            \\            __workerPushDone(self, finish);
            \\        }
            \\        fn finish(ctx: *anyopaque) void {
            \\            const self: *@This() = @ptrCast(@alignCast(ctx));
            \\            self.promise.resolve(self.result);
            \\        }
            \\    };
            \\    const p = LumenPromise(T).create();
            \\    const st = __alloc.create(State) catch unreachable;
            \\    st.* = .{ .f = f, .promise = p };
            \\    const th = std.Thread.spawn(.{}, State.threadMain, .{st}) catch unreachable;
            \\    th.detach();
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_fd_api) {
        // A Lumen "fd" is an index into this table, not a raw OS handle (so the
        // type stays a plain `int`). openSync supports only "r" (read, must
        // exist) and "w" (write, create/truncate) -- "a" (append) needs a seek
        // primitive not available in this Zig version's std.Io.File, so it is
        // deferred. readSync/writeSync work on `string`, not a Buffer type
        // (Lumen has none yet), and are sequential (advance the OS file
        // position), matching Node's positionless readSync/writeSync.
        try out.appendSlice(arena,
            \\// Open files, shared by every thread. A handler calling openSync from
            \\// an HTTP worker appends here while another reads items[fd], and an
            \\// append that grows the list frees the array the reader is holding.
            \\//
            \\// The lock covers the table, not the I/O: a File is a small handle,
            \\// so it is copied out under the lock and read or written outside it.
            \\// Holding the lock across a blocking read would serialise every file
            \\// operation in the process to fix a problem that is only about the
            \\// list's backing memory.
            \\var __fd_table: std.ArrayListUnmanaged(std.Io.File) = .empty;
            \\var __fd_lock: std.Io.Mutex = .init;
            \\fn __fdAt(io: std.Io, fd: i32) ?std.Io.File {
            \\    if (fd < 0) return null;
            \\    __fd_lock.lockUncancelable(io);
            \\    defer __fd_lock.unlock(io);
            \\    if (@as(usize, @intCast(fd)) >= __fd_table.items.len) return null;
            \\    return __fd_table.items[@intCast(fd)];
            \\}
            \\fn __openSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8, flags: []const u8) i32 {
            \\    const file = if (std.mem.eql(u8, flags, "w"))
            \\        std.Io.Dir.cwd().createFile(io, path, .{}) catch return -1
            \\    else if (std.mem.eql(u8, flags, "a")) blk: {
            \\        // Append mode (spec 031 revisited again): std.Io.File's
            \\        // write path issues a raw, position-implicit writev(),
            \\        // so seating the kernel's own fd offset at EOF once via
            \\        // a raw lseek is enough -- every later writeSync call
            \\        // naturally continues from there, no per-call seek or
            \\        // offset tracking needed.
            \\        const f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return -1;
            \\        if (@import("builtin").os.tag == .linux) _ = std.os.linux.lseek(f.handle, 0, std.os.linux.SEEK.END);
            \\        break :blk f;
            \\    } else
            \\        std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return -1;
            \\    __fd_lock.lockUncancelable(io);
            \\    defer __fd_lock.unlock(io);
            \\    __fd_table.append(alloc, file) catch return -1;
            \\    return @intCast(__fd_table.items.len - 1);
            \\}
            \\fn __closeSync(io: std.Io, fd: i32) void {
            \\    var file = __fdAt(io, fd) orelse return;
            \\    file.close(io);
            \\}
            \\fn __readSync(io: std.Io, alloc: std.mem.Allocator, fd: i32, len: i32) []const u8 {
            \\    if (len <= 0) return "";
            \\    var file = __fdAt(io, fd) orelse return "";
            \\    const buf = alloc.alloc(u8, @intCast(len)) catch return "";
            \\    const n = file.readStreaming(io, &.{buf}) catch return "";
            \\    return buf[0..n];
            \\}
            \\fn __writeSync(io: std.Io, fd: i32, data: []const u8) i32 {
            \\    var file = __fdAt(io, fd) orelse return 0;
            \\    file.writeStreamingAll(io, data) catch return 0;
            \\    return @intCast(data.len);
            \\}
            \\
        );
    }
    if (program.needs_rmdir_sync) {
        try out.appendSlice(arena,
            \\fn __rmdirSync(io: std.Io, path: []const u8) void {
            \\    std.Io.Dir.cwd().deleteDir(io, path) catch {};
            \\}
            \\
        );
    }
    if (program.needs_rm_sync) {
        try out.appendSlice(arena,
            \\fn __rmSync(io: std.Io, path: []const u8, recursive: bool) void {
            \\    if (recursive) {
            \\        std.Io.Dir.cwd().deleteTree(io, path) catch {};
            \\    } else {
            \\        std.Io.Dir.cwd().deleteFile(io, path) catch {
            \\            std.Io.Dir.cwd().deleteDir(io, path) catch {};
            \\        };
            \\    }
            \\}
            \\
        );
    }
    if (program.needs_truncate_sync) {
        try out.appendSlice(arena,
            \\fn __truncateSync(io: std.Io, path: []const u8, len: i64) void {
            \\    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch return;
            \\    defer file.close(io);
            \\    file.setLength(io, @intCast(len)) catch {};
            \\}
            \\
        );
    }
    if (program.needs_link_sync) {
        try out.appendSlice(arena,
            \\fn __linkSync(io: std.Io, existing_path: []const u8, new_path: []const u8) void {
            \\    std.Io.Dir.hardLink(std.Io.Dir.cwd(), existing_path, std.Io.Dir.cwd(), new_path, io, .{}) catch {};
            \\}
            \\
        );
    }
    if (program.needs_symlink_sync) {
        try out.appendSlice(arena,
            \\fn __symlinkSync(io: std.Io, target: []const u8, path: []const u8) void {
            \\    std.Io.Dir.cwd().symLink(io, target, path, .{}) catch {};
            \\}
            \\
        );
    }
    if (program.needs_readlink_sync) {
        try out.appendSlice(arena,
            \\fn __readlinkSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) []const u8 {
            \\    var buf: [4096]u8 = undefined;
            \\    const n = std.Io.Dir.cwd().readLink(io, path, &buf) catch return "";
            \\    return alloc.dupe(u8, buf[0..n]) catch "";
            \\}
            \\
        );
    }
    if (program.needs_chmod_sync) {
        try out.appendSlice(arena,
            \\fn __chmodSync(io: std.Io, path: []const u8, mode: i64) void {
            \\    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return;
            \\    defer file.close(io);
            \\    file.setPermissions(io, std.Io.File.Permissions.fromMode(@intCast(mode))) catch {};
            \\}
            \\
        );
    }
    if (program.needs_access_sync) {
        try out.appendSlice(arena,
            \\fn __accessSync(io: std.Io, path: []const u8, mode: i64) bool {
            \\    const m: u32 = @intCast(mode);
            \\    const opts: std.Io.Dir.AccessOptions = .{
            \\        .read = (m & 4) != 0,
            \\        .write = (m & 2) != 0,
            \\        .execute = (m & 1) != 0,
            \\    };
            \\    std.Io.Dir.cwd().access(io, path, opts) catch return false;
            \\    return true;
            \\}
            \\
        );
    }
    if (program.needs_lstat_sync) {
        // Same `__LumenStat` record as statSync, but `follow_symlinks = false`
        // so a symlink itself is stat'd rather than its target.
        try out.appendSlice(arena,
            \\fn __lstatSync(io: std.Io, path: []const u8) __LumenStat {
            \\    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return .{ .size = 0, .isFile = false, .isDirectory = false, .mtimeMs = 0 };
            \\    return .{
            \\        .size = @truncate(@as(i64, @intCast(st.size))),
            \\        .isFile = st.kind == .file,
            \\        .isDirectory = st.kind == .directory,
            \\        .mtimeMs = @truncate(@divTrunc(@as(i96, st.mtime.nanoseconds), 1_000_000)),
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_fstat_sync) {
        // fd-based variant of statSync: stats the already-open file in
        // __fd_table rather than re-resolving a path.
        try out.appendSlice(arena,
            \\fn __fstatSync(io: std.Io, fd: i32) __LumenStat {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return .{ .size = 0, .isFile = false, .isDirectory = false, .mtimeMs = 0 };
            \\    const st = __fd_table.items[@intCast(fd)].stat(io) catch return .{ .size = 0, .isFile = false, .isDirectory = false, .mtimeMs = 0 };
            \\    return .{
            \\        .size = @truncate(@as(i64, @intCast(st.size))),
            \\        .isFile = st.kind == .file,
            \\        .isDirectory = st.kind == .directory,
            \\        .mtimeMs = @truncate(@divTrunc(@as(i96, st.mtime.nanoseconds), 1_000_000)),
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_fchmod_sync) {
        try out.appendSlice(arena,
            \\fn __fchmodSync(io: std.Io, fd: i32, mode: i64) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].setPermissions(io, std.Io.File.Permissions.fromMode(@intCast(mode))) catch {};
            \\}
            \\
        );
    }
    if (program.needs_lchmod_sync) {
        // Best effort: not every OS lets you chmod a symlink directly: this
        // opens without following the symlink, then sets permissions on
        // whatever that resolves to.
        try out.appendSlice(arena,
            \\fn __lchmodSync(io: std.Io, path: []const u8, mode: i64) void {
            \\    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .follow_symlinks = false }) catch return;
            \\    defer file.close(io);
            \\    file.setPermissions(io, std.Io.File.Permissions.fromMode(@intCast(mode))) catch {};
            \\}
            \\
        );
    }
    if (program.needs_fchown_sync) {
        try out.appendSlice(arena,
            \\fn __fchownSync(io: std.Io, fd: i32, uid: i64, gid: i64) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    const u: ?std.posix.uid_t = if (uid < 0) null else @intCast(uid);
            \\    const g: ?std.posix.gid_t = if (gid < 0) null else @intCast(gid);
            \\    __fd_table.items[@intCast(fd)].setOwner(io, u, g) catch {};
            \\}
            \\
        );
    }
    if (program.needs_chown_sync) {
        // fs.chownSync (spec 031 revisited): the path-based Dir.setFileOwner
        // is an unconditional @panic in this Zig version's Io.Threaded
        // backend on Linux, confirmed still true by reading the source
        // directly -- genuinely blocked at that layer. But File.setOwner
        // (the fd-based one fchownSync already uses) is a real, working
        // implementation, not a stub. So this opens the file first and uses
        // that instead, the same "open, then use the file-level method"
        // pattern chmodSync already established, sidestepping the broken
        // path-level wrapper entirely.
        try out.appendSlice(arena,
            \\fn __chownSync(io: std.Io, path: []const u8, uid: i64, gid: i64) void {
            \\    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return;
            \\    defer file.close(io);
            \\    const u: ?std.posix.uid_t = if (uid < 0) null else @intCast(uid);
            \\    const g: ?std.posix.gid_t = if (gid < 0) null else @intCast(gid);
            \\    file.setOwner(io, u, g) catch {};
            \\}
            \\
        );
    }
    if (program.needs_lchown_sync) {
        // fs.lchownSync (spec 031 revisited again): must not follow a
        // symlink, so chownSync's "open the file, use File.setOwner" trick
        // doesn't apply here -- there's no way to open a path without
        // following a symlink in this Zig version. But std.os.linux already
        // has a ready-made lchown raw syscall wrapper (fchownat with
        // AT.SYMLINK_NOFOLLOW under the hood), the same "raw Linux syscall,
        // no libc, no std.Io" pattern fs.watch/writevSync already
        // established. No `io` parameter needed -- this never touches
        // std.Io at all.
        try out.appendSlice(arena,
            \\fn __lchownSync(path: []const u8, uid: i64, gid: i64) void {
            \\    if (@import("builtin").os.tag != .linux) return;
            \\    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return;
            \\    defer std.heap.page_allocator.free(path_z);
            \\    const u: std.posix.uid_t = if (uid < 0) ~@as(std.posix.uid_t, 0) else @intCast(uid);
            \\    const g: std.posix.gid_t = if (gid < 0) ~@as(std.posix.gid_t, 0) else @intCast(gid);
            \\    _ = std.os.linux.lchown(path_z, u, g);
            \\}
            \\
        );
    }
    if (program.needs_writev_sync) {
        // fs.writevSync (spec 031 revisited): std.Io.File has no vectored
        // write wrapper in this Zig version (confirmed absent, not just
        // unused), but the raw std.os.linux.writev syscall does exist --
        // the same "raw Linux syscall, no libc" pattern os.uptime()/
        // fs.watch already established.
        try out.appendSlice(arena,
            \\fn __writevSync(fd: i32, bufs: []const []const u8) i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return 0;
            \\    const handle = __fd_table.items[@intCast(fd)].handle;
            \\    const iov = std.heap.page_allocator.alloc(std.posix.iovec_const, bufs.len) catch return 0;
            \\    defer std.heap.page_allocator.free(iov);
            \\    for (bufs, 0..) |b, i| iov[i] = .{ .base = b.ptr, .len = b.len };
            \\    const n = std.os.linux.writev(handle, iov.ptr, iov.len);
            \\    return @intCast(n);
            \\}
            \\
        );
    }
    if (program.needs_readv_sync) {
        // fs.readvSync (spec 031 revisited again): reframed, not a direct
        // port of Node's signature. Node's readv fills caller-provided
        // *mutable* buffers, which has no natural shape given Lumen's
        // `string` is immutable. Instead this takes int[] sizes and
        // allocates+owns the buffers itself, doing one real readv syscall
        // to fill them all, then hands back fresh immutable strings sized
        // to what was actually read -- same underlying vectored read, a
        // shape that fits the type system instead of fighting it. readv
        // fills earlier buffers completely before moving to later ones, so
        // slicing each allocated buffer against the remaining byte count
        // (in order) recovers exactly how much each one actually got.
        try out.appendSlice(arena,
            \\fn __readvSync(alloc: std.mem.Allocator, fd: i32, sizes: []const i32) []const []const u8 {
            \\    if (@import("builtin").os.tag != .linux) return &.{};
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return &.{};
            \\    const handle = __fd_table.items[@intCast(fd)].handle;
            \\    const bufs = alloc.alloc([]u8, sizes.len) catch return &.{};
            \\    const iov = alloc.alloc(std.posix.iovec, sizes.len) catch return &.{};
            \\    for (sizes, 0..) |sz, i| {
            \\        const b = alloc.alloc(u8, @intCast(@max(sz, 0))) catch return &.{};
            \\        bufs[i] = b;
            \\        iov[i] = .{ .base = b.ptr, .len = b.len };
            \\    }
            \\    const rc = std.os.linux.readv(handle, iov.ptr, iov.len);
            \\    if (@as(isize, @bitCast(rc)) < 0) return &.{};
            \\    var remaining: usize = rc;
            \\    const result = alloc.alloc([]const u8, sizes.len) catch return &.{};
            \\    for (bufs, 0..) |b, i| {
            \\        const take = @min(b.len, remaining);
            \\        result[i] = b[0..take];
            \\        remaining -= take;
            \\    }
            \\    return result;
            \\}
            \\
        );
    }
    if (program.needs_fsync_sync) {
        // Backs both fsyncSync and fdatasyncSync: Zig's std.Io.File has no
        // data-only sync, so fdatasyncSync is treated as a full sync.
        try out.appendSlice(arena,
            \\fn __fsyncSync(io: std.Io, fd: i32) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].sync(io) catch {};
            \\}
            \\
        );
    }
    if (program.needs_ftruncate_sync) {
        try out.appendSlice(arena,
            \\fn __ftruncateSync(io: std.Io, fd: i32, len: i64) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].setLength(io, @intCast(len)) catch {};
            \\}
            \\
        );
    }
    if (program.needs_futimes_sync) {
        try out.appendSlice(arena,
            \\fn __futimesSync(io: std.Io, fd: i32, atime_ms: i64, mtime_ms: i64) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].setTimestamps(io, .{
            \\        .access_timestamp = .{ .new = .{ .nanoseconds = @as(i96, atime_ms) * 1_000_000 } },
            \\        .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, mtime_ms) * 1_000_000 } },
            \\    }) catch {};
            \\}
            \\
        );
    }
    if (program.needs_utimes_sync) {
        // Backs both utimesSync (follow_symlinks=true) and lutimesSync (false).
        try out.appendSlice(arena,
            \\fn __utimesSync(io: std.Io, path: []const u8, atime_ms: i64, mtime_ms: i64, follow_symlinks: bool) void {
            \\    std.Io.Dir.cwd().setTimestamps(io, path, .{
            \\        .follow_symlinks = follow_symlinks,
            \\        .access_timestamp = .{ .new = .{ .nanoseconds = @as(i96, atime_ms) * 1_000_000 } },
            \\        .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, mtime_ms) * 1_000_000 } },
            \\    }) catch {};
            \\}
            \\
        );
    }
    if (program.needs_readdir_sync) {
        // string[] is already a plain []const []const u8 slice (not a
        // growable list), so this is a two-pass count-then-fill: no
        // Array.push language feature needed.
        try out.appendSlice(arena,
            \\fn __readdirSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) []const []const u8 {
            \\    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return &.{};
            \\    defer dir.close(io);
            \\    var count: usize = 0;
            \\    {
            \\        var it = dir.iterate();
            \\        while (it.next(io) catch null) |_| count += 1;
            \\    }
            \\    const names = alloc.alloc([]const u8, count) catch return &.{};
            \\    var it2 = dir.iterate();
            \\    var i: usize = 0;
            \\    while (i < count) {
            \\        const entry = (it2.next(io) catch null) orelse break;
            \\        names[i] = alloc.dupe(u8, entry.name) catch entry.name;
            \\        i += 1;
            \\    }
            \\    return names[0..i];
            \\}
            \\
        );
    }
    if (program.needs_fs_watch) {
        // fs.watch (spec 044): raw inotify, the same "raw Linux syscall, no
        // libc" pattern os.uptime()/uname() already established. Blocking,
        // like http.createServer -- there's no background mechanism to
        // drive an EventEmitter asynchronously here, so this calls
        // `listener` synchronously in a loop that never returns, rather
        // than returning an EventEmitter-based watcher object the way
        // Node's real fs.watch does.
        try out.appendSlice(arena,
            \\fn __fsWatch(path: []const u8, listener: anytype) noreturn {
            \\    if (@import("builtin").os.tag != .linux) std.process.exit(1);
            \\    const inotify = std.os.linux.inotify_init1(0);
            \\    if (@as(isize, @bitCast(inotify)) < 0) std.process.exit(1);
            \\    const fd: i32 = @intCast(inotify);
            \\    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch std.process.exit(1);
            \\    const mask: u32 = std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE | std.os.linux.IN.MOVE;
            \\    const wd = std.os.linux.inotify_add_watch(fd, path_z, mask);
            \\    if (@as(isize, @bitCast(wd)) < 0) std.process.exit(1);
            \\    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
            \\    while (true) {
            \\        const n = std.posix.read(fd, &buf) catch continue;
            \\        var offset: usize = 0;
            \\        while (offset + @sizeOf(std.os.linux.inotify_event) <= n) {
            \\            const ev: *const std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[offset]));
            \\            const name = ev.getName() orelse path;
            \\            // Node's fs.watch only distinguishes "change" (data
            \\            // modified) from "rename" (created/deleted/moved),
            \\            // not inotify's full event granularity -- matching
            \\            // that convention rather than inventing a new one.
            \\            const event_type: []const u8 = if (ev.mask & std.os.linux.IN.MODIFY != 0) "change" else "rename";
            \\            listener.call(listener.ctx, name, event_type);
            \\            offset += @sizeOf(std.os.linux.inotify_event) + ev.len;
            \\        }
            \\    }
            \\}
            \\
        );
    }
    if (program.needs_fs_streams) {
        // fs.createReadStream/createWriteStream (spec 046): built the same
        // way as Map/Set/EventEmitter (a dedicated, non-generic type), not
        // via Lumen's own array syntax (which has no growable-array support
        // to build one with anyway). Synchronous, blocking .read()/.write()
        // calls -- no async/backpressure integration in this pass. A
        // missing/unopenable file degrades to a stream where .read() always
        // returns "" and .close() is a no-op, the same "return a fallback,
        // don't crash" shape every other fs function already uses.
        try out.appendSlice(arena,
            \\pub const LumenReadableStream = struct {
            \\    file: ?std.Io.File,
            \\    io: std.Io,
            \\    reader: std.Io.File.Reader = undefined,
            \\    fn __init(io: std.Io, file: ?std.Io.File) *LumenReadableStream {
            \\        const p = __sa().create(LumenReadableStream) catch unreachable;
            \\        p.* = .{ .file = file, .io = io };
            \\        if (file) |f| {
            \\            const buf = __sa().alloc(u8, 65536) catch unreachable;
            \\            p.reader = f.readerStreaming(io, buf);
            \\        }
            \\        return p;
            \\    }
            \\    fn read(self: *LumenReadableStream) []const u8 {
            \\        if (self.file == null) return "";
            \\        var scratch: [65536]u8 = undefined;
            \\        const n = self.reader.interface.readSliceShort(&scratch) catch return "";
            \\        if (n == 0) return "";
            \\        return __sa().dupe(u8, scratch[0..n]) catch "";
            \\    }
            \\    // readLine() (spec 053): takeDelimiterInclusive is the same
            \\    // primitive __httpCreateServer's request-line/header parsing
            \\    // already proved out for "read up to and including the next
            \\    // \n" over a std.Io.Reader interface. Deliberately does NOT
            \\    // strip the trailing terminator (see spec.md's "Line
            \\    // reading" section): stripping it would make a genuinely
            \\    // blank line and true end-of-stream both collapse to the
            \\    // same "", making a `while (readLine() != "")` loop stop
            \\    // early on ordinary blank input lines -- a real correctness
            \\    // bug, confirmed directly by testing piped input containing
            \\    // a blank line before fixing this. Only true EOF (checked
            \\    // via takeDelimiterInclusive's EndOfStream, then draining
            \\    // whatever partial bytes -- if any -- are still buffered
            \\    // for a final unterminated line) returns "".
            \\    fn readLine(self: *LumenReadableStream) []const u8 {
            \\        if (self.file == null) return "";
            \\        const raw = self.reader.interface.takeDelimiterInclusive('\n') catch |e| blk: {
            \\            if (e != error.EndOfStream) break :blk "";
            \\            const left = self.reader.interface.buffered();
            \\            if (left.len == 0) break :blk "";
            \\            self.reader.interface.toss(left.len);
            \\            break :blk left;
            \\        };
            \\        if (raw.len == 0) return "";
            \\        return __sa().dupe(u8, raw) catch "";
            \\    }
            \\    fn close(self: *LumenReadableStream) void {
            \\        if (self.file) |f| f.close(self.io);
            \\    }
            \\};
            \\fn __fsCreateReadStream(io: std.Io, path: []const u8) *LumenReadableStream {
            \\    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch null;
            \\    return LumenReadableStream.__init(io, file);
            \\}
            \\pub const LumenWritableStream = struct {
            \\    file: ?std.Io.File,
            \\    io: std.Io,
            \\    writer: std.Io.File.Writer = undefined,
            \\    // flush_each_write (spec 053): off by default so
            \\    // fs.createWriteStream's existing buffered-until-close
            \\    // behavior is unchanged; process.stdout()/stderr() turn this
            \\    // on so writes interleave correctly with console.log, which
            \\    // flushes every call -- see spec 053's "unflushed stdout
            \\    // writes" section.
            \\    flush_each_write: bool = false,
            \\    fn __init(io: std.Io, file: ?std.Io.File) *LumenWritableStream {
            \\        const p = __sa().create(LumenWritableStream) catch unreachable;
            \\        p.* = .{ .file = file, .io = io };
            \\        if (file) |f| {
            \\            const buf = __sa().alloc(u8, 65536) catch unreachable;
            \\            p.writer = f.writerStreaming(io, buf);
            \\        }
            \\        return p;
            \\    }
            \\    fn write(self: *LumenWritableStream, chunk: []const u8) void {
            \\        if (self.file == null) return;
            \\        self.writer.interface.writeAll(chunk) catch {};
            \\        if (self.flush_each_write) self.writer.interface.flush() catch {};
            \\    }
            \\    fn close(self: *LumenWritableStream) void {
            \\        if (self.file) |f| {
            \\            self.writer.interface.flush() catch {};
            \\            f.close(self.io);
            \\        }
            \\    }
            \\};
            \\fn __fsCreateWriteStream(io: std.Io, path: []const u8) *LumenWritableStream {
            \\    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch null;
            \\    return LumenWritableStream.__init(io, file);
            \\}
            \\
        );
    }
}

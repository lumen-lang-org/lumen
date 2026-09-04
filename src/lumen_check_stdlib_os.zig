//! Type-checking for the OS-facing stdlib namespaces: `fs.*`, `path.*`,
//! `process.*`, `os.*`, `child_process.*`, and `readline.*`. Split out of
//! `lumen_check_stdlib.zig` purely by size; the dispatcher (`staticCallType`)
//! and the remaining namespaces stay there.
//!
//! Same convention as `lumen_check_stdlib.zig`: each function is a `Checker`
//! method physically defined here (explicit `self: *Checker` first parameter)
//! and aliased back onto the `Checker` type in `lumen_check.zig`, relying on
//! Zig's support for circular *references* between files.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;

pub fn fsCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "readFileSync")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const encoding_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.same(.string, encoding_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_read_file_sync = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "existsSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_exists_sync = true;
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "realpathSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_realpath_sync = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "writeFileSync") or std.mem.eql(u8, call.name, "appendFileSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const data_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.same(.string, data_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        if (std.mem.eql(u8, call.name, "writeFileSync")) program.needs_write_file_sync = true else program.needs_append_file_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "mkdirSync")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const recursive_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.same(.bool, recursive_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_mkdir_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "unlinkSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_unlink_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "renameSync") or std.mem.eql(u8, call.name, "copyFileSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, a_type) or !types.same(.string, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        if (std.mem.eql(u8, call.name, "renameSync")) program.needs_rename_sync = true else program.needs_copy_file_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "rmdirSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_rmdir_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "rmSync")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const recursive_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.same(.bool, recursive_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_rm_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "truncateSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const len_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(len_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_truncate_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "linkSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, a_type) or !types.same(.string, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_link_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "symlinkSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, a_type) or !types.same(.string, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_symlink_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "readlinkSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_readlink_sync = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "chmodSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const mode_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(mode_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_chmod_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "accessSync")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const mode_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.isInteger(mode_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_access_sync = true;
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "cpSync")) {
        if (call.args.len != 2 and call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, a_type) or !types.same(.string, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 3) {
            const recursive_type = self.exprType(program, call.args[2], line, col) orelse return null;
            if (!types.same(.bool, recursive_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_cp_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "mkdtempSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const prefix_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, prefix_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_mkdtemp_sync = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "statSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // A builtin record return: lazily register a synthetic record type
        // (`__LumenStat`) the first time a stat-family function is used, then
        // return it like any user-declared `type X = {...}`. This is a
        // deliberate deviation from Node: isFile/isDirectory are plain bool
        // fields here, not methods (Lumen has no method dispatch on a
        // builtin-record type yet).
        registerLumenStat(self) orelse return null;
        program.uses_io = true;
        program.needs_stat_sync = true;
        call.checked_type = .{ .named = "__LumenStat" };
        return .{ .named = "__LumenStat" };
    }
    if (std.mem.eql(u8, call.name, "openSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const flags_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.same(.string, flags_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fd_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "closeSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(fd_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fd_api = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "readSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const len_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.isInteger(len_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fd_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "writeSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const data_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.same(.string, data_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fd_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "readFile")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // `fs.readFile(path)` -> `Promise<string>`, read via libxev's io_uring
        // backend (true async file I/O, no thread pool) instead of the
        // synchronous `fs.readFileSync`.
        const p = self.arena.create(types.Type) catch return null;
        p.* = .string;
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_async_read_file = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "writeFile")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const data_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.same(.string, data_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // `fs.writeFile(path, data)` -> `Promise<void>`, the async counterpart
        // to `fs.readFile` -- true non-blocking I/O, no thread pool.
        const p = self.arena.create(types.Type) catch return null;
        p.* = .void;
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_async_write_file = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "appendFile")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const data_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.same(.string, data_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // `fs.appendFile(path, data)` -> `Promise<void>`, the async counterpart
        // to `fs.appendFileSync`.
        const p = self.arena.create(types.Type) catch return null;
        p.* = .void;
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_async_append_file = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "unlink")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // `fs.unlink(path)` -> `Promise<void>` (spec 047): unlike
        // readFile/writeFile/appendFile, this runs on a real thread pool --
        // libxev's own OperationType union has no async unlink primitive on
        // any backend (checked directly), so this dispatches the blocking
        // syscall to a worker thread and bridges the result back via
        // xev.Async, the same pattern libxev's own kqueue backend uses
        // internally for its file I/O.
        const p = self.arena.create(types.Type) catch return null;
        p.* = .void;
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_thread_pool_fs = true;
        program.needs_async_unlink = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "mkdir")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const p = self.arena.create(types.Type) catch return null;
        p.* = .void;
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_thread_pool_fs = true;
        program.needs_async_mkdir = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "rmdir")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const p = self.arena.create(types.Type) catch return null;
        p.* = .void;
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_thread_pool_fs = true;
        program.needs_async_rmdir = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "stat")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenStat(self) orelse return null;
        const p = self.arena.create(types.Type) catch return null;
        p.* = .{ .named = "__LumenStat" };
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_thread_pool_fs = true;
        program.needs_stat_sync = true;
        program.needs_async_stat = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "lstatSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenStat(self) orelse return null;
        program.uses_io = true;
        program.needs_lstat_sync = true;
        call.checked_type = .{ .named = "__LumenStat" };
        return .{ .named = "__LumenStat" };
    }
    if (std.mem.eql(u8, call.name, "fstatSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(fd_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenStat(self) orelse return null;
        program.uses_io = true;
        program.needs_fstat_sync = true;
        call.checked_type = .{ .named = "__LumenStat" };
        return .{ .named = "__LumenStat" };
    }
    if (std.mem.eql(u8, call.name, "fchmodSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const mode_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.isInteger(mode_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fchmod_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "lchmodSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const mode_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(mode_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_lchmod_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "fchownSync")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const uid_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const gid_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.isInteger(uid_type) or !types.isInteger(gid_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fchown_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "chownSync")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const uid_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const gid_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(uid_type) or !types.isInteger(gid_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_chown_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "lchownSync")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const uid_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const gid_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(uid_type) or !types.isInteger(gid_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.needs_lchown_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "writevSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const bufs_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.same(.string_array, bufs_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_writev_sync = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "readvSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const sizes_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.same(.i32_array, sizes_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_readv_sync = true;
        call.checked_type = .string_array;
        return .string_array;
    }
    if (std.mem.eql(u8, call.name, "fsyncSync") or std.mem.eql(u8, call.name, "fdatasyncSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(fd_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fsync_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "ftruncateSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const len_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.isInteger(len_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_ftruncate_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "futimesSync")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const atime_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const mtime_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.isInteger(atime_type) or !types.isInteger(mtime_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_futimes_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "utimesSync") or std.mem.eql(u8, call.name, "lutimesSync")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const atime_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const mtime_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(atime_type) or !types.isInteger(mtime_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_utimes_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "readdirSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_readdir_sync = true;
        call.checked_type = .string_array;
        return .string_array;
    }
    if (std.mem.eql(u8, call.name, "watch")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const want = self.makeFuncType(&.{ .string, .string }, .void) orelse return null;
        self.ensureAssignable(program, want, call.args[1], line, col) catch {
            return null;
        };
        program.needs_fs_watch = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "createReadStream")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fs_streams = true;
        call.checked_type = .readable_stream_type;
        return .readable_stream_type;
    }
    if (std.mem.eql(u8, call.name, "createWriteStream")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fs_streams = true;
        call.checked_type = .writable_stream_type;
        return .writable_stream_type;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

// Lazily registers the synthetic `__LumenStat` record type (shared by
// statSync/lstatSync/fstatSync) into the same `type_decls` map a user
// `type X = {...}` declaration would use. See statSync above for the full
// rationale; this just factors out the now-repeated registration so each
// stat-family branch can call it without duplicating the field list.
fn registerLumenStat(self: *Checker) ?void {
    if (self.type_decls.get("__LumenStat") == null) {
        const fields = self.arena.alloc(ast.TypeField, 4) catch return null;
        fields[0] = .{ .name = "size", .annotation = "int", .checked_type = .i32 };
        fields[1] = .{ .name = "isFile", .annotation = "bool", .checked_type = .bool };
        fields[2] = .{ .name = "isDirectory", .annotation = "bool", .checked_type = .bool };
        fields[3] = .{ .name = "mtimeMs", .annotation = "int", .checked_type = .i32 };
        self.type_decls.put(self.arena, "__LumenStat", .{ .fields = fields }) catch return null;
    }
}

// `path.*` (spec 032): pure string manipulation, no `std.Io`/syscalls --
// unlike every `fs.*` function, nothing here ever touches `io`. It still
// sets `program.uses_io` purely to get the prologue to declare `__alloc`
// (the codegen ties that declaration to the same flag as `__io`'s; several
// path functions allocate even though none of them do file I/O).
pub fn pathCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "basename")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (call.args) |a| {
            const t = self.exprType(program, a, line, col) orelse return null;
            if (!types.same(.string, t)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "dirname") or std.mem.eql(u8, call.name, "extname") or std.mem.eql(u8, call.name, "normalize")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "isAbsolute")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "join")) {
        if (call.args.len < 2 or call.args.len > 6) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (call.args) |a| {
            const t = self.exprType(program, a, line, col) orelse return null;
            if (!types.same(.string, t)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "resolve")) {
        if (call.args.len < 1 or call.args.len > 6) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (call.args) |a| {
            const t = self.exprType(program, a, line, col) orelse return null;
            if (!types.same(.string, t)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "parse")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenPathParts(self) orelse return null;
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .{ .named = "__LumenPathParts" };
        return .{ .named = "__LumenPathParts" };
    }
    if (std.mem.eql(u8, call.name, "format")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        registerLumenPathParts(self) orelse return null;
        self.ensureAssignable(program, .{ .named = "__LumenPathParts" }, call.args[0], line, col) catch {
            return null;
        };
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .string;
        return .string;
    }
    // `path.sep()` / `path.delimiter()`: Node exposes these as plain string
    // properties (`path.sep`, no call), but Lumen has no static-namespace
    // constant-property mechanism yet -- only call dispatch. Exposed as
    // zero-arg functions instead; a deliberate, documented deviation rather
    // than inventing a whole new expression form for two constants.
    if (std.mem.eql(u8, call.name, "sep") or std.mem.eql(u8, call.name, "delimiter")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .string;
        return .string;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

// Lazily registers the synthetic `__LumenPathParts` record type (shared by
// `path.parse`'s return value and `path.format`'s parameter), following the
// exact pattern `registerLumenStat` introduced for `fs.statSync`. All five
// fields are plain (non-optional) strings -- a deliberate simplification vs.
// Node, where `path.format`'s argument may omit any field. Round-tripping
// `path.format(path.parse(p))` works perfectly; constructing a literal by
// hand requires every field.
fn registerLumenPathParts(self: *Checker) ?void {
    if (self.type_decls.get("__LumenPathParts") == null) {
        const fields = self.arena.alloc(ast.TypeField, 5) catch return null;
        fields[0] = .{ .name = "root", .annotation = "string", .checked_type = .string };
        fields[1] = .{ .name = "dir", .annotation = "string", .checked_type = .string };
        fields[2] = .{ .name = "base", .annotation = "string", .checked_type = .string };
        fields[3] = .{ .name = "name", .annotation = "string", .checked_type = .string };
        fields[4] = .{ .name = "ext", .annotation = "string", .checked_type = .string };
        self.type_decls.put(self.arena, "__LumenPathParts", .{ .fields = fields }) catch return null;
    }
}

// `process.*` (spec 033): mixed bag -- cwd/chdir/env go through std.process's
// own Io-abstracted primitives (so they need `io`, like `fs`); platform/arch
// are compile-time constants; pid/argv are cheap reads of state Zig's own
// entry already captured, no Io involved at all (argv reuses the existing
// `__args` machinery `argsCount()`/`arg(i)` already set up).
pub fn processCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "cwd")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "chdir")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "sleep")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "exit")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "env")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        const inner = self.arena.create(types.Type) catch return null;
        inner.* = .string;
        const result = types.Type{ .optional = inner };
        call.checked_type = result;
        return result;
    }
    if (std.mem.eql(u8, call.name, "platform") or std.mem.eql(u8, call.name, "arch")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "pid")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "argv")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        program.needs_args = true;
        call.checked_type = .string_array;
        return .string_array;
    }
    // process API completion (spec 050): uptime/hrtime reuse the same
    // Io.Clock primitive spec 041's time.now()/time.monotonic() already
    // wired up. uptime() additionally needs a start timestamp recorded once
    // in main(), gated by its own needs_process_uptime flag (the other
    // functions in this namespace don't need any main()-time setup).
    if (std.mem.eql(u8, call.name, "uptime")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        program.needs_process_uptime = true;
        call.checked_type = .f64;
        return .f64;
    }
    // hrtime() is a scalar i64 nanosecond count, not Node's [seconds, ns]
    // tuple -- see spec.md's "hrtime shape" section for why: Lumen's i64 is
    // a real 64-bit integer (not an IEEE-754 double), so it doesn't have
    // the precision problem the tuple exists to work around in JS.
    if (std.mem.eql(u8, call.name, "hrtime")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .i64;
        return .i64;
    }
    if (std.mem.eql(u8, call.name, "memoryUsage")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        registerLumenProcessMemory(self) orelse return null;
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .{ .named = "__LumenProcessMemory" };
        return .{ .named = "__LumenProcessMemory" };
    }
    if (std.mem.eql(u8, call.name, "kill")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const pid_t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(pid_t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const sig_t = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, sig_t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "umask")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "setUmask")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    // getuid/getgid/geteuid/getegid (spec 050): POSIX-only, same shape as
    // the existing pid() -- raw syscalls, 0 fallback on non-Linux targets.
    if (std.mem.eql(u8, call.name, "getuid") or std.mem.eql(u8, call.name, "getgid") or
        std.mem.eql(u8, call.name, "geteuid") or std.mem.eql(u8, call.name, "getegid"))
    {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "abort")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .void;
        return .void;
    }
    // Lumen's own version marker, not Node's -- see spec.md's "version
    // marker" section.
    if (std.mem.eql(u8, call.name, "version")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .string;
        return .string;
    }
    // stdio streams (spec 053): process.stdin()/stdout()/stderr() reuse
    // spec 046's exact ReadableStream/WritableStream types, just wired to
    // the real stdio fds instead of an opened file -- see spec.md's "Why
    // reuse spec 046's types verbatim" section. needs_fs_streams is set
    // alongside needs_process_stdio so the shared struct definitions are
    // emitted even in a program that never calls
    // fs.createReadStream/createWriteStream directly.
    if (std.mem.eql(u8, call.name, "stdin")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fs_streams = true;
        program.needs_process_stdio = true;
        call.checked_type = .readable_stream_type;
        return .readable_stream_type;
    }
    if (std.mem.eql(u8, call.name, "stdout") or std.mem.eql(u8, call.name, "stderr")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fs_streams = true;
        program.needs_process_stdio = true;
        call.checked_type = .writable_stream_type;
        return .writable_stream_type;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

// Lazily registers the synthetic `__LumenProcessMemory` record type shared
// by `process.memoryUsage()`, following the same pattern
// `registerLumenStat`/`registerLumenPathParts` already established. Only
// `rss`/`vsize` -- see spec.md's "memoryUsage(): which /proc/self/status
// fields are real" section for why those two and not a faked Node-shaped
// heap breakdown.
fn registerLumenProcessMemory(self: *Checker) ?void {
    if (self.type_decls.get("__LumenProcessMemory") == null) {
        const fields = self.arena.alloc(ast.TypeField, 2) catch return null;
        fields[0] = .{ .name = "rss", .annotation = "i64", .checked_type = .i64 };
        fields[1] = .{ .name = "vsize", .annotation = "i64", .checked_type = .i64 };
        self.type_decls.put(self.arena, "__LumenProcessMemory", .{ .fields = fields }) catch return null;
    }
}

// `os.*` (spec 034): almost entirely two syscalls (uname, sysinfo), no libc.
// `platform()`/`arch()` intentionally duplicate `process.*`'s mapping rather
// than share it at the language level -- Node defines both independently
// with identical values, so this matches Node's actual shape.
pub fn osCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    const string_fns = [_][]const u8{
        "platform", "arch",       "type",   "release", "version", "machine",
        "hostname", "endianness", "tmpdir", "homedir", "EOL",     "devNull",
    };
    for (string_fns) |name| {
        if (std.mem.eql(u8, call.name, name)) {
            if (call.args.len != 0) {
                _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                return null;
            }
            program.uses_io = true;
            program.needs_os_api = true;
            // Every os.* helper is emitted as one unconditional block, and
            // Zig checks top-level declarations eagerly (not only when
            // called) -- so __osTmpdir/__osHomedir's reference to
            // __processEnv must resolve even if the program never calls
            // tmpdir()/homedir(). Simplest fix: any os.* usage pulls in
            // process's __environ/__processEnv machinery (spec 033), not
            // just the two functions that actually need it.
            program.needs_process_api = true;
            call.checked_type = .string;
            return .string;
        }
    }
    const int_fns = [_][]const u8{ "uptime", "totalmem", "freemem", "availableParallelism" };
    for (int_fns) |name| {
        if (std.mem.eql(u8, call.name, name)) {
            if (call.args.len != 0) {
                _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                return null;
            }
            program.uses_io = true;
            program.needs_os_api = true;
            program.needs_process_api = true;
            call.checked_type = .i32;
            return .i32;
        }
    }
    if (std.mem.eql(u8, call.name, "loadavg")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_os_api = true;
        program.needs_process_api = true;
        call.checked_type = .f64_array;
        return .f64_array;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

/// Validate a `readline.*` static call (spec 058). One function, reusing
/// `process.stdin()`/`process.stdout()` directly -- see spec.md.
pub fn readlineCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "question")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const prompt_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, prompt_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fs_streams = true;
        program.needs_process_stdio = true;
        program.needs_readline = true;
        call.checked_type = .string;
        return .string;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn childProcessCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "spawnSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cmd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const args_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, cmd_type) or !types.same(.string_array, args_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenSpawnResult(self) orelse return null;
        program.uses_io = true;
        program.needs_child_process_api = true;
        call.checked_type = .{ .named = "__LumenSpawnResult" };
        return .{ .named = "__LumenSpawnResult" };
    }
    // child_process.spawn (spec 450): the persistent variant. Same argument
    // validation as spawnSync, but returns a long-lived ChildProcess handle
    // (mirrors net.connect returning a Socket) instead of a one-shot result
    // record.
    if (std.mem.eql(u8, call.name, "spawn")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cmd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const args_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, cmd_type) or !types.same(.string_array, args_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_child_process_spawn = true;
        call.checked_type = .process_type;
        return .process_type;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

// Lazily registers the synthetic `__LumenSpawnResult` record type returned by
// `child_process.spawnSync`, following the exact pattern
// `registerLumenPathParts`/`registerLumenUrlParts` introduced.
fn registerLumenSpawnResult(self: *Checker) ?void {
    if (self.type_decls.get("__LumenSpawnResult") == null) {
        const fields = self.arena.alloc(ast.TypeField, 3) catch return null;
        fields[0] = .{ .name = "stdout", .annotation = "string", .checked_type = .string };
        fields[1] = .{ .name = "stderr", .annotation = "string", .checked_type = .string };
        fields[2] = .{ .name = "status", .annotation = "int", .checked_type = .i32 };
        self.type_decls.put(self.arena, "__LumenSpawnResult", .{ .fields = fields }) catch return null;
    }
}

// `assert.*`: wraps the language's own panic mechanism rather than the
// throw/catch machinery, since a static call has no access to an enclosing
// try's throw target. A failed assertion crashes the program (uncatchable),
// the same idiom as C's assert() or an uncaught Node AssertionError.

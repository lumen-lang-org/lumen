//! `Class.*` — the three things the compiler knows about a class that a
//! program could not reach (spec 477).
//!
//!   Class.nameOf(c)                    the class's declared name
//!   Class.decorator(c, "controller")   the constant that decorator left behind
//!   Class.invoke(c, name, args...)     the method named by a run-time string
//!
//! None of the three survives into the emitter. Each is resolved here, while
//! checking, and the call is rewritten in place: a string literal, a reference
//! to the decorator's constant, and a call to a generated dispatcher function.
//! So there is no reflection in the binary and no metadata section — the same
//! trade spec 455 made for decorators, one level down.
//!
//! The dispatcher matters most. Its branches are *direct* method calls, which
//! is the shape spec 245/247 already propagate a throw through, so a `try`
//! around `Class.invoke` catches a throwing method. That is what lets a
//! framework guard every handler once, in the framework, instead of asking
//! every call site to remember its own `try`.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const parser_mod = @import("lumen_parser.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;

/// The namespace as written. A local binding of the same name shadows it, the
/// way every other namespace in the checker behaves.
pub const namespace = "Class";

/// Type-check and rewrite one `Class.*` call. `e` is the whole expression, so
/// the call can be replaced by what it resolves to; `call` points inside it and
/// must not be read after `e` is overwritten.
pub fn classMetaCall(self: *Checker, program: *ast.Program, e: *ast.Expr, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    const which = call.name;
    const is_name = std.mem.eql(u8, which, "nameOf");
    const is_decorator = std.mem.eql(u8, which, "decorator");
    const is_invoke = std.mem.eql(u8, which, "invoke");
    if (!is_name and !is_decorator and !is_invoke) {
        _ = self.fail(line, col, "`Class` offers `nameOf`, `decorator` and `invoke`") catch {};
        return null;
    }
    if (call.args.len == 0) {
        const msg = std.fmt.allocPrint(self.arena, "`Class.{s}` reads a class instance, so it takes one first", .{which}) catch "Class.* takes a class instance";
        _ = self.fail(line, col, msg) catch {};
        return null;
    }
    const recv_type = self.exprType(program, call.args[0], line, col) orelse return null;
    if (recv_type != .class_type) {
        const msg = std.fmt.allocPrint(self.arena, "`Class.{s}` reads a class instance, and this is {s}", .{ which, types.tsName(self.arena, recv_type) catch "another type" }) catch "Class.* reads a class instance";
        _ = self.fail(line, col, msg) catch {};
        return null;
    }
    const cname = recv_type.class_type;

    if (is_name) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "`Class.nameOf` takes the object and nothing else") catch {};
            return null;
        }
        e.* = .{ .str = cname };
        return .string;
    }
    if (is_decorator) return decoratorConstant(self, e, call, cname, line, col);
    return invokeMethod(self, program, e, call, cname, line, col);
}

/// `Class.decorator(c, "controller")` — the constant `@controller` left beside
/// the class, by spec 455 D4's `<decorator><Class>` naming rule. Rewritten to a
/// plain reference to it, so the program reads the same binding it would have
/// written by hand — only without having to know its name.
fn decoratorConstant(self: *Checker, e: *ast.Expr, call: *ast.StaticCall, cname: []const u8, line: u32, col: u32) ?types.Type {
    if (call.args.len != 2 or call.args[1].* != .str) {
        _ = self.fail(line, col, "`Class.decorator` takes the object and the decorator's name as a literal: Class.decorator(c, \"controller\")") catch {};
        return null;
    }
    const dname = call.args[1].str;
    if (dname.len == 0) {
        _ = self.fail(line, col, "`Class.decorator` needs the decorator's name") catch {};
        return null;
    }
    // spec 455 D4: `@controller` on `AgentApi` gives `controllerAgentApi`.
    const const_name = std.fmt.allocPrint(self.arena, "{s}{s}", .{ dname, cname }) catch return null;
    const_name[dname.len] = std.ascii.toUpper(const_name[dname.len]);

    const b = self.binding(const_name) orelse {
        const msg = std.fmt.allocPrint(self.arena, "`{s}` carries no `@{s}`, so there is no `{s}` to read", .{ cname, dname, const_name }) catch "no such decorator on this class";
        // Inside a specialized generic — `mount<Plain>` — the line that matters
        // is the call that named the class, not the library line that wrote
        // `Class.decorator` for every class there will ever be (spec 478).
        const at = self.spec_site orelse [2]u32{ line, col };
        _ = self.fail(at[0], at[1], msg) catch {};
        return null;
    };
    e.* = .{ .var_ref = .{ .name = const_name, .emit_name = b.emit_name } };
    return b.ty;
}

/// `Class.invoke(c, name, args...)` — rewritten to a call to a dispatcher
/// generated once per (class, argument types).
fn invokeMethod(self: *Checker, program: *ast.Program, e: *ast.Expr, call: *ast.StaticCall, cname: []const u8, line: u32, col: u32) ?types.Type {
    if (call.args.len < 2) {
        _ = self.fail(line, col, "`Class.invoke` takes the object, the method's name, and that method's arguments") catch {};
        return null;
    }
    const name_type = self.exprType(program, call.args[1], line, col) orelse return null;
    if (name_type != .string) {
        _ = self.fail(line, col, "the second argument to `Class.invoke` is the method's name, so it is a string") catch {};
        return null;
    }

    const argc = call.args.len - 2;
    const arg_types = self.arena.alloc(types.Type, argc) catch return null;
    for (call.args[2..], 0..) |a, i| {
        arg_types[i] = self.exprType(program, a, line, col) orelse return null;
    }

    const disp = dispatcherName(self, cname, arg_types) catch return null;
    if (self.funcs.get(disp) == null) {
        generateDispatcher(self, disp, cname, arg_types, line, col) catch |err| {
            if (err == error.OutOfMemory) return null;
            return null;
        };
    }

    // Hand the rewritten call back to the ordinary call path: argument checking,
    // `emit_name`, and the throwing-call machinery all apply to it unchanged.
    const args = call.args;
    e.* = .{ .call = .{ .name = disp, .args = args } };
    return self.exprType(program, e, line, col);
}

/// One dispatcher per class and argument-type list, named so a second
/// `Class.invoke` with the same shape reuses it.
fn dispatcherName(self: *Checker, cname: []const u8, arg_types: []const types.Type) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(self.arena, "__dispatch_");
    try buf.appendSlice(self.arena, cname);
    for (arg_types) |t| {
        try buf.append(self.arena, '_');
        const ann = (try types.toAnnotation(self.arena, t)) orelse "x";
        for (ann) |ch| try buf.append(self.arena, if (std.ascii.isAlphanumeric(ch)) ch else '_');
    }
    return buf.items;
}

/// A method of `cname` (or a base) that `Class.invoke` may dispatch to.
const Candidate = struct { name: []const u8, ret: []const u8, bind: ?[]const []const u8 = null, guard: ?[]const u8 = null };

/// The Lumen expression a parameter binds to, when it carries one of the
/// request-binding decorators, or null when it does not.
///
/// The dispatcher is generated as source, so binding is a matter of writing the
/// call the handler would otherwise have written by hand. `param`, `queryParam`
/// and `header` resolve because every module is flattened into one program and
/// `rest/server.ts` declares them there.
fn bindingFor(self: *Checker, p: ast.FunctionParam, req: []const u8) !?[]const u8 {
    // An undecorated `Request` parameter binds to the request itself, so a
    // handler may take both — `save(req: Request, @Valid @RequestBody ask: Ask)`.
    // Without this the whole method stops being a candidate the moment one
    // parameter is the request, and it silently loses its @Valid rules.
    if (p.decorators.len == 0) {
        if (std.mem.eql(u8, p.annotation, "Request")) return req;
        return null;
    }
    for (p.decorators) |d| {
        const first: []const u8 = if (d.args.len > 0) switch (d.args[0]) {
            .str => |v| v,
            else => "",
        } else "";
        const second: []const u8 = if (d.args.len > 1) switch (d.args[1]) {
            .str => |v| v,
            else => "",
        } else "";
        const named = if (first.len > 0) first else p.name;
        const wants_int = std.mem.eql(u8, p.annotation, "int") or std.mem.eql(u8, p.annotation, "i32");

        if (std.mem.eql(u8, d.name, "PathVariable") or std.mem.eql(u8, d.name, "path")) {
            const raw = try std.fmt.allocPrint(self.arena, "param({s}, \"{s}\")", .{ req, named });
            return if (wants_int) try std.fmt.allocPrint(self.arena, "parseInt({s}, 10) ?? 0", .{raw}) else raw;
        }
        if (std.mem.eql(u8, d.name, "RequestParam") or std.mem.eql(u8, d.name, "query")) {
            const raw = try std.fmt.allocPrint(self.arena, "queryParam({s}, \"{s}\", \"{s}\")", .{ req, named, second });
            return if (wants_int) try std.fmt.allocPrint(self.arena, "parseInt({s}, 10) ?? 0", .{raw}) else raw;
        }
        if (std.mem.eql(u8, d.name, "RequestHeader") or std.mem.eql(u8, d.name, "header")) {
            return try std.fmt.allocPrint(self.arena, "header({s}, \"{s}\")", .{ req, named });
        }
        // A named resolver: @From("owner") binds owner(req). The whole of a
        // user-defined binder, because the dispatcher already writes arbitrary
        // expressions — a resolver is any function taking the request.
        if (std.mem.eql(u8, d.name, "From") or std.mem.eql(u8, d.name, "from")) {
            if (first.len == 0) return null;
            return try std.fmt.allocPrint(self.arena, "{s}({s})", .{ first, req });
        }
        if (std.mem.eql(u8, d.name, "RequestBody") or std.mem.eql(u8, d.name, "body")) {
            if (std.mem.eql(u8, p.annotation, "string")) {
                return try std.fmt.allocPrint(self.arena, "{s}.body", .{req});
            }
            return try std.fmt.allocPrint(self.arena, "JSON.parse<{s}>({s}.body)", .{ p.annotation, req });
        }
    }
    return null;
}

/// Build, parse, declare and queue the dispatcher. Generated rather than
/// hand-built as an AST because the thing generated is ordinary Lumen — a chain
/// of `if`s over direct method calls — and reading it in this file is how the
/// next person will know what `Class.invoke` means.
fn generateDispatcher(
    self: *Checker,
    disp: []const u8,
    cname: []const u8,
    arg_types: []const types.Type,
    line: u32,
    col: u32,
) diag_mod.CompileError!void {
    var cands: std.ArrayListUnmanaged(Candidate) = .empty;
    var params: ?[]const []const u8 = null;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    var cur: ?[]const u8 = cname;
    while (cur) |cn| {
        const info = self.classes.get(cn) orelse break;
        for (info.methods) |m| {
            if (m.is_static or m.accessor != .none or m.is_async or m.visibility != .public) continue;
            // A derived class's definition takes the name, matching or not — an
            // override that changed its signature hides the base, it does not
            // fall through to it.
            if (seen.get(m.name) != null) continue;
            try seen.put(self.arena, m.name, {});
            var matches = m.params.len == arg_types.len;
            if (matches) for (m.params, arg_types) |p, at| {
                if (p.is_rest or p.default != null or p.annotation.len == 0) {
                    matches = false;
                    break;
                }
                const pt = self.typeFromAnnotation(p.annotation, line, col) catch {
                    matches = false;
                    break;
                };
                if (!types.same(pt, at)) {
                    matches = false;
                    break;
                }
            };
            // A method whose parameters carry request-binding decorators is a
            // candidate even though its signature is not the dispatched one:
            // the dispatcher binds each parameter out of the single request
            // rather than passing it through. That is the whole of
            // @RequestBody / @PathVariable / @RequestParam / @RequestHeader.
            var bind: ?[]const []const u8 = null;
            var guard: ?[]const u8 = null;
            if (!matches and arg_types.len == 1 and m.params.len > 0) {
                const bs = try self.arena.alloc([]const u8, m.params.len);
                var all = true;
                for (m.params, 0..) |p, bi| {
                    const b = (try bindingFor(self, p, "__a0")) orelse {
                        all = false;
                        break;
                    };
                    bs[bi] = b;
                }
                if (all) {
                    bind = bs;
                    matches = true;
                    // @Valid beside @RequestBody: run the rules the type carries
                    // before the handler sees anything. The constant is the one
                    // @validated left, resolved the same way Class.decorator
                    // resolves it, so a type with no rules simply has no guard.
                    for (m.params) |p| {
                        var valid = false;
                        var body = false;
                        for (p.decorators) |d| {
                            if (std.mem.eql(u8, d.name, "Valid") or std.mem.eql(u8, d.name, "valid")) valid = true;
                            if (std.mem.eql(u8, d.name, "RequestBody") or std.mem.eql(u8, d.name, "body")) body = true;
                        }
                        if (!valid or !body or p.annotation.len == 0) continue;
                        const rulesName = try std.fmt.allocPrint(self.arena, "validated{s}", .{p.annotation});
                        rulesName[9] = std.ascii.toUpper(rulesName[9]);
                        if (self.binding(rulesName) == null) continue;
                        guard = try std.fmt.allocPrint(
                            self.arena,
                            "let __v = validationRefusal({s}, __a0.body); if (__v != \"\") {{ return badRequest(__v); }} ",
                            .{rulesName},
                        );
                    }
                }
            }
            for (m.decorators) |d| {
                if (!std.mem.eql(u8, d.name, "Guard") and !std.mem.eql(u8, d.name, "guard")) continue;
                if (d.args.len == 0) continue;
                const fname = switch (d.args[0]) {
                    .str => |v| v,
                    else => continue,
                };
                if (fname.len == 0) continue;
                const before = guard orelse "";
                const n = cands.items.len;
                // A guard that is a method of this class is called on the
                // instance and takes nothing — that is how it reaches `this.db`
                // without taking a Request, which would make it a dispatch
                // candidate and collide with the handlers' return type.
                var owned = false;
                var scan: ?[]const u8 = cname;
                while (scan) |sn| {
                    const ci = self.classes.get(sn) orelse break;
                    for (ci.methods) |cm| {
                        if (std.mem.eql(u8, cm.name, fname) and cm.params.len == 0) owned = true;
                    }
                    scan = ci.parent;
                }
                // Arguments after the name are forwarded, so policy can be
                // parameterised — @Guard("roleAtLeast", "admin") calls
                // roleAtLeast(req, "admin"). The guard itself lives in the
                // application, not in rest: rest owns the mechanism.
                var extra: std.ArrayListUnmanaged(u8) = .empty;
                for (d.args[1..]) |a| {
                    try extra.appendSlice(self.arena, ", ");
                    switch (a) {
                        .str => |v| try extra.print(self.arena, "\"{s}\"", .{v}),
                        .int => |v| try extra.print(self.arena, "{d}", .{v}),
                        .flt => |v| try extra.print(self.arena, "{d}", .{v}),
                        .boolean => |v| try extra.appendSlice(self.arena, if (v) "true" else "false"),
                    }
                }
                const call = if (owned)
                    try std.fmt.allocPrint(self.arena, "__self.{s}({s})", .{ fname, if (extra.items.len > 2) extra.items[2..] else "" })
                else
                    try std.fmt.allocPrint(self.arena, "{s}(__a0{s})", .{ fname, extra.items });
                guard = try std.fmt.allocPrint(
                    self.arena,
                    "{s}let __g{d} = {s}; if (__g{d}.stop) {{ return __g{d}.reply; }} ",
                    .{ before, n, call, n, n },
                );
            }
            if (!matches) continue;
            const ret = if (m.return_annotation.len > 0)
                m.return_annotation
            else if (m.checked_return_type) |rt|
                ((try types.toAnnotation(self.arena, rt)) orelse continue)
            else
                continue;
            if (cands.items.len > 0 and !std.mem.eql(u8, cands.items[0].ret, ret)) {
                const msg = try std.fmt.allocPrint(self.arena, "`{s}.{s}` returns {s} and `{s}.{s}` returns {s}; `Class.invoke` dispatches over methods that agree on a return type", .{ cname, cands.items[0].name, cands.items[0].ret, cname, m.name, ret });
                return self.fail(line, col, msg);
            }
            if (params == null) {
                // From the dispatched argument types, not from the method's own
                // parameters: a bound method's parameters are what it wants,
                // while the dispatcher is always called with the request.
                const ps = try self.arena.alloc([]const u8, arg_types.len);
                for (arg_types, 0..) |at, i| ps[i] = (try types.toAnnotation(self.arena, at)) orelse "string";
                params = ps;
            }
            try cands.append(self.arena, .{ .name = m.name, .ret = ret, .bind = bind, .guard = guard });
        }
        cur = info.parent;
    }

    if (cands.items.len == 0) {
        const msg = try std.fmt.allocPrint(self.arena, "no method of `{s}` takes these {d} argument(s), so there is nothing for `Class.invoke` to dispatch to", .{ cname, arg_types.len });
        return self.fail(line, col, msg);
    }

    var src: std.ArrayListUnmanaged(u8) = .empty;
    try src.print(self.arena, "function {s}(__self: {s}, __handler: string", .{ disp, cname });
    for (params.?, 0..) |ann, i| try src.print(self.arena, ", __a{d}: {s}", .{ i, ann });
    try src.print(self.arena, "): {s} {{\n", .{cands.items[0].ret});
    for (cands.items) |c| {
        try src.print(self.arena, "  if (__handler == \"{s}\") {{ ", .{c.name});
        if (c.guard) |g| try src.appendSlice(self.arena, g);
        try src.print(self.arena, "return __self.{s}(", .{c.name});
        if (c.bind) |bs| {
            for (bs, 0..) |b, i| {
                if (i > 0) try src.appendSlice(self.arena, ", ");
                try src.appendSlice(self.arena, b);
            }
        } else {
            for (params.?, 0..) |_, i| {
                if (i > 0) try src.appendSlice(self.arena, ", ");
                try src.print(self.arena, "__a{d}", .{i});
            }
        }
        try src.appendSlice(self.arena, "); }\n");
    }
    try src.print(self.arena, "  throw new Error(\"{s} has no method named \\\"\" + __handler + \"\\\"\");\n}}\n", .{cname});

    var p = try parser_mod.Parser.init(self.arena, src.items);
    const prog = p.parseProgram() catch return self.fail(line, col, "a dispatcher for `Class.invoke` could not be built");
    if (prog.stmts.len != 1 or prog.stmts[0] != .function_decl) return self.fail(line, col, "a dispatcher for `Class.invoke` could not be built");

    const decl = try self.arena.create(ast.FunctionDecl);
    decl.* = prog.stmts[0].function_decl;
    // The generated function has no line of its own; point it at the call that
    // asked for it, so anything reported against it lands where the user wrote.
    decl.line = line;
    decl.col = col;

    try self.declareFunction(null, decl);
    const stmt_ptr = try self.arena.create(ast.Stmt);
    stmt_ptr.* = .{ .function_decl = decl.* };
    try self.pending_specializations.append(self.arena, stmt_ptr);
}

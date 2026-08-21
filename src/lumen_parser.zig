//! The parser -- stage 2 of the compiler.
//!
//! Consumes the lexer's token stream and produces the AST (`lumen_ast.zig`). It is
//! a hand-written recursive-descent parser: `Parser.init(arena, source)` wraps a
//! `Lexer`, and `Parser.parseProgram()` returns a `Program`. The parser only knows
//! about tokens and AST nodes -- it does no type checking and no code generation
//! (those are `lumen_check.zig` and the codegen in `lumen_compiler.zig`).
//!
//! Errors are reported as `error.ParseError`; the caller turns the lexer's current
//! position into a user-facing diagnostic. Type annotations are kept as raw source
//! strings on the AST and resolved later by the checker.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const lexer = @import("lumen_lexer.zig");
const diag_mod = @import("lumen_diag.zig");
const parser_expr = @import("lumen_parser_expr.zig");
const parser_decl = @import("lumen_parser_decl.zig");

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Program = ast.Program;
const FieldInit = ast.FieldInit;
const Lexer = lexer.Lexer;
const Tok = lexer.Tok;

/// Names the parser treats as built-in calls rather than user identifiers.
fn isBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "httpGet") or std.mem.eql(u8, name, "serve");
}

pub const Parser = struct {
    // Type-annotation and expression parsing lives in lumen_parser_expr.zig.
    pub const parseTypeMember = parser_expr.parseTypeMember;
    pub const consumeTypeArgClose = parser_expr.consumeTypeArgClose;
    pub const parseFunctionType = parser_expr.parseFunctionType;
    pub const parseTupleType = parser_expr.parseTupleType;
    pub const parseTypeAnnotation = parser_expr.parseTypeAnnotation;
    pub const parseExpr = parser_expr.parseExpr;
    pub const parseSpreadOrExpr = parser_expr.parseSpreadOrExpr;
    pub const parseTemplateParts = parser_expr.parseTemplateParts;
    pub const isCmp = parser_expr.isCmp;
    pub const isComparison = parser_expr.isComparison;
    pub const parseTernary = parser_expr.parseTernary;
    pub const parseCoalesce = parser_expr.parseCoalesce;
    pub const parseOr = parser_expr.parseOr;
    pub const parseAnd = parser_expr.parseAnd;
    pub const parseBitOr = parser_expr.parseBitOr;
    pub const parseBitXor = parser_expr.parseBitXor;
    pub const parseBitAnd = parser_expr.parseBitAnd;
    pub const parseCmp = parser_expr.parseCmp;
    pub const parseRelational = parser_expr.parseRelational;
    pub const parseShift = parser_expr.parseShift;
    pub const parseAdd = parser_expr.parseAdd;
    pub const parseMul = parser_expr.parseMul;
    pub const parseExp = parser_expr.parseExp;
    pub const parseUnary = parser_expr.parseUnary;
    pub const parsePostfix = parser_expr.parsePostfix;
    pub const parsePostfixFrom = parser_expr.parsePostfixFrom;
    pub const looksLikeArrow = parser_expr.looksLikeArrow;
    pub const isCompoundAssignOp = parser_expr.isCompoundAssignOp;
    pub const parseArrow = parser_expr.parseArrow;
    pub const parseDeferHelperBodyStmt = parser_expr.parseDeferHelperBodyStmt;
    pub const parsePrimary = parser_expr.parsePrimary;
    pub const parseAssignmentTail = parser_expr.parseAssignmentTail;
    pub const parsePrefixUpdate = parser_expr.parsePrefixUpdate;

    // Declaration parsing lives in lumen_parser_decl.zig.
    pub const parseTypeDecl = parser_decl.parseTypeDecl;
    pub const parseOptionalMember = parser_decl.parseOptionalMember;
    pub const parseExternDecl = parser_decl.parseExternDecl;
    pub const parseInterfaceDecl = parser_decl.parseInterfaceDecl;
    pub const parseEnumDecl = parser_decl.parseEnumDecl;
    pub const parseFunctionDecl = parser_decl.parseFunctionDecl;
    pub const parseParamList = parser_decl.parseParamList;
    pub const parseTypeParams = parser_decl.parseTypeParams;
    pub const parseTypeArgs = parser_decl.parseTypeArgs;
    pub const looksLikeTypeArgs = parser_decl.looksLikeTypeArgs;
    pub const parseClassDecl = parser_decl.parseClassDecl;
    pub const parseDecorators = parser_decl.parseDecorators;

    arena: std.mem.Allocator,
    lex: Lexer,
    cur: Tok,
    cur_line: u32 = 1, // source line of `cur`
    cur_col: u32 = 1, // source column of `cur`
    prev_line: u32 = 1, // source line of the token consumed just before `cur` (for ASI)
    last_err: []const u8 = "syntax error", // message for the next diagnostic

    pub fn init(arena: std.mem.Allocator, src: []const u8) CompileError!Parser {
        var lex = Lexer{ .src = src };
        const first = try lex.next();
        return .{ .arena = arena, .lex = lex, .cur = first, .cur_line = lex.tok_line, .cur_col = lex.tok_col };
    }
    pub fn advance(self: *Parser) CompileError!void {
        self.prev_line = self.cur_line;
        self.cur = try self.lex.next();
        self.cur_line = self.lex.tok_line;
        self.cur_col = self.lex.tok_col;
    }
    /// A statement terminator: a literal `;`, or ASI — the next token is on a new
    /// line, is a closing `}`, or is EOF. Covers the common no-semicolon style.
    pub fn expectSemi(self: *Parser) CompileError!void {
        if (self.isOp(';')) {
            try self.advance();
            return;
        }
        if (self.cur == .eof or self.isOp('}') or self.cur_line > self.prev_line) return;
        self.last_err = std.fmt.allocPrint(self.arena, "expected end of statement (';' or a newline), found {s}", .{self.describeCur()}) catch "syntax error";
        return error.ParseError;
    }
    pub fn isOp(self: *Parser, ch: u8) bool {
        return self.cur == .op and self.cur.op == ch;
    }
    pub fn isOp2(self: *Parser, op: []const u8) bool {
        return self.cur == .op2 and std.mem.eql(u8, self.cur.op2, op);
    }
    pub fn isSpread(self: *Parser) bool {
        return self.cur == .op3 and std.mem.eql(u8, self.cur.op3, "...");
    }
    pub fn oneExpr(self: *Parser, value: i64) CompileError!*Expr {
        return self.node(.{ .num = value });
    }
    /// A short human description of the current token, for parse diagnostics.
    pub fn describeCur(self: *Parser) []const u8 {
        return switch (self.cur) {
            .num, .flt => "a number",
            .str => "a string",
            .template => "a template literal",
            .regex => "a regex literal",
            .op => |c| std.fmt.allocPrint(self.arena, "'{c}'", .{c}) catch "a symbol",
            .op2 => |s| std.fmt.allocPrint(self.arena, "'{s}'", .{s}) catch "a symbol",
            .op3 => |s| std.fmt.allocPrint(self.arena, "'{s}'", .{s}) catch "a symbol",
            .cmp => |s| std.fmt.allocPrint(self.arena, "'{s}'", .{s}) catch "a symbol",
            .ident => |s| std.fmt.allocPrint(self.arena, "'{s}'", .{s}) catch "an identifier",
            .eof => "end of file",
        };
    }

    pub fn expectOp(self: *Parser, ch: u8) CompileError!void {
        if (!self.isOp(ch)) {
            self.last_err = std.fmt.allocPrint(self.arena, "expected '{c}', found {s}", .{ ch, self.describeCur() }) catch "syntax error";
            return error.ParseError;
        }
        try self.advance();
    }
    pub fn isKw(self: *Parser, kw: []const u8) bool {
        return self.cur == .ident and std.mem.eql(u8, self.cur.ident, kw);
    }
    /// True when the token after `cur` is `(`. Restores parser state afterwards.
    fn peekIsOpenParen(self: *Parser) bool {
        const save_lex = self.lex;
        const save_cur = self.cur;
        const save_line = self.cur_line;
        const save_col = self.cur_col;
        const save_prev = self.prev_line;
        self.advance() catch {};
        const result = self.isOp('(');
        self.lex = save_lex;
        self.cur = save_cur;
        self.cur_line = save_line;
        self.cur_col = save_col;
        self.prev_line = save_prev;
        return result;
    }
    /// True when the token after `cur` is `:`. Restores parser state afterwards.
    /// Used to recognize a labeled statement `name:` at statement start.
    fn peekIsColon(self: *Parser) bool {
        const save_lex = self.lex;
        const save_cur = self.cur;
        const save_line = self.cur_line;
        const save_col = self.cur_col;
        const save_prev = self.prev_line;
        self.advance() catch {};
        const result = self.isOp(':');
        self.lex = save_lex;
        self.cur = save_cur;
        self.cur_line = save_line;
        self.cur_col = save_col;
        self.prev_line = save_prev;
        return result;
    }
    /// Whether the token after the current one is the identifier `word`, without
    /// consuming either (used for two-keyword forms like `const enum`).
    fn peekIsKw(self: *Parser, word: []const u8) bool {
        const save_lex = self.lex;
        const save_cur = self.cur;
        const save_line = self.cur_line;
        const save_col = self.cur_col;
        const save_prev = self.prev_line;
        self.advance() catch {};
        const result = self.cur == .ident and std.mem.eql(u8, self.cur.ident, word);
        self.lex = save_lex;
        self.cur = save_cur;
        self.cur_line = save_line;
        self.cur_col = save_col;
        self.prev_line = save_prev;
        return result;
    }
    pub fn node(self: *Parser, e: Expr) CompileError!*Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
    }
    pub fn isStdNamespace(name: []const u8) bool {
        return std.mem.eql(u8, name, "Math") or std.mem.eql(u8, name, "String") or std.mem.eql(u8, name, "Array") or std.mem.eql(u8, name, "fs") or std.mem.eql(u8, name, "Promise") or std.mem.eql(u8, name, "path") or std.mem.eql(u8, name, "process") or std.mem.eql(u8, name, "os") or std.mem.eql(u8, name, "crypto") or std.mem.eql(u8, name, "url") or std.mem.eql(u8, name, "child_process") or std.mem.eql(u8, name, "assert") or std.mem.eql(u8, name, "time") or std.mem.eql(u8, name, "http") or std.mem.eql(u8, name, "JSON") or std.mem.eql(u8, name, "net") or std.mem.eql(u8, name, "zlib") or std.mem.eql(u8, name, "Buffer") or std.mem.eql(u8, name, "readline") or std.mem.eql(u8, name, "Worker") or std.mem.eql(u8, name, "Number") or std.mem.eql(u8, name, "Date") or std.mem.eql(u8, name, "Object") or std.mem.eql(u8, name, "Class");
    }
    pub fn parseBlock(self: *Parser) CompileError![]Stmt {
        try self.expectOp('{');
        var body: std.ArrayListUnmanaged(Stmt) = .empty;
        while (!self.isOp('}')) {
            if (self.cur == .eof) {
                self.last_err = "expected '}' to close this block, found end of file";
                return error.ParseError;
            }
            try body.append(self.arena, try self.parseStmt());
        }
        try self.expectOp('}');
        return body.toOwnedSlice(self.arena);
    }

    /// A control-flow body: either a `{ ... }` block or a single unbraced
    /// statement (`if (c) return x;`, `for (...) sum += i;`), wrapped as a
    /// one-element body.
    pub fn parseBlockOrStmt(self: *Parser) CompileError![]Stmt {
        if (self.isOp('{')) return self.parseBlock();
        const one = try self.arena.alloc(Stmt, 1);
        one[0] = try self.parseStmt();
        return one;
    }

    fn parseSwitchBody(self: *Parser) CompileError![]Stmt {
        var body: std.ArrayListUnmanaged(Stmt) = .empty;
        while (!self.isOp('}') and !self.isKw("case") and !self.isKw("default")) {
            try body.append(self.arena, try self.parseStmt());
        }
        return body.toOwnedSlice(self.arena);
    }

    fn parseSwitch(self: *Parser, line: u32, col: u32) CompileError!Stmt {
        try self.advance();
        try self.expectOp('(');
        const value = try self.parseExpr();
        try self.expectOp(')');
        try self.expectOp('{');
        var cases: std.ArrayListUnmanaged(ast.SwitchCase) = .empty;
        var default_body: ?[]Stmt = null;
        while (!self.isOp('}')) {
            if (self.isKw("case")) {
                const case_line = self.cur_line;
                const case_col = self.cur_col;
                try self.advance();
                const case_value = try self.parseExpr();
                try self.expectOp(':');
                try cases.append(self.arena, .{ .value = case_value, .body = try self.parseSwitchBody(), .line = case_line, .col = case_col });
            } else if (self.isKw("default")) {
                if (default_body != null) return error.ParseError;
                try self.advance();
                try self.expectOp(':');
                default_body = try self.parseSwitchBody();
            } else {
                return error.ParseError;
            }
        }
        try self.expectOp('}');
        return .{ .switch_stmt = .{ .value = value, .cases = try cases.toOwnedSlice(self.arena), .default_body = default_body, .line = line, .col = col } };
    }

    fn parseStmt(self: *Parser) CompileError!Stmt {
        const eq = std.mem.eql;
        const line = self.cur_line;
        const col = self.cur_col;
        if (self.cur == .op2 and (std.mem.eql(u8, self.cur.op2, "++") or std.mem.eql(u8, self.cur.op2, "--"))) {
            const op = self.cur.op2;
            return .{ .assign = try self.parsePrefixUpdate(op, line, col, true) };
        }
        // `@name(...)` before a declaration (spec 455). The target is checked
        // before the declaration is parsed, so the diagnostic lands on the
        // offending keyword rather than wherever the statement happened to end.
        if (self.isOp('@')) {
            const decorators = try self.parseDecorators();
            const is_async_fn = self.isKw("async") and self.peekIsKw("function");
            if (!self.isKw("class") and !self.isKw("function") and !is_async_fn) {
                self.last_err = "E_DECORATOR_TARGET";
                return error.ParseError;
            }
            var decl = try self.parseStmt();
            switch (decl) {
                .class_decl => |*c| c.decorators = decorators,
                .function_decl => |*f| f.decorators = decorators,
                else => {
                    self.last_err = "E_DECORATOR_TARGET";
                    return error.ParseError;
                },
            }
            return decl;
        }
        // An expression statement whose leading token is not an identifier —
        // e.g. a method call on an array/string literal or a parenthesized
        // expression (`[1,2].forEach(...)`, `"x".repeat(3)`, `(e).m()`).
        if (self.cur != .ident) {
            // A bare `{ ... }` at statement position is a block (a nested scope),
            // never an object literal (JS/TS statement-position rule).
            if (self.isOp('{')) {
                const inner = try self.parseBlock();
                return .{ .block_stmt = .{ .body = inner, .line = line, .col = col } };
            }
            if (self.isOp('[') or self.isOp('(') or self.cur == .str or self.cur == .num or self.cur == .flt or self.cur == .template) {
                const value = try self.parseExpr();
                // Array destructuring assignment `[a, b] = expr;` (e.g. a swap):
                // the targets are existing variables, not new bindings.
                if (self.isOp('=') and value.* == .array) {
                    try self.advance(); // '='
                    const rhs = try self.parseExpr();
                    try self.expectSemi();
                    const binds = try self.arena.alloc(ast.DestructBinding, value.array.items.len);
                    for (value.array.items, 0..) |it, i| {
                        // Only simple variable targets are supported (no nested
                        // patterns or member targets).
                        if (it.* != .var_ref) return error.ParseError;
                        binds[i] = .{ .name = it.var_ref.name };
                    }
                    return .{ .destructure_decl = .{ .mutable = true, .is_object = false, .is_assignment = true, .bindings = binds, .source = rhs, .line = line, .col = col } };
                }
                try self.expectSemi();
                return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
            }
            return error.ParseError;
        }
        const kw = self.cur.ident;

        // Labeled statement `name: <loop>` (spec 052). A bare `ident :` at
        // statement start is unambiguously a label (no other statement form
        // begins that way); it must be followed by a loop, else a parse error.
        if (self.peekIsColon()) {
            const label_name = kw;
            try self.advance(); // ident
            try self.advance(); // ':'
            var loop = try self.parseStmt();
            switch (loop) {
                .while_stmt => |*w| w.label = label_name,
                .do_while_stmt => |*d| d.label = label_name,
                .for_stmt => |*f| f.label = label_name,
                .for_of_stmt => |*f| f.label = label_name,
                .for_in_stmt => |*f| f.label = label_name,
                else => return error.ParseError, // a label must front a loop
            }
            return loop;
        }

        // `await <expr>;` as a statement (the resolved value is discarded).
        if (eq(u8, kw, "await")) {
            const value = try self.parseExpr();
            try self.expectSemi();
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "type")) return self.parseTypeDecl(line, col);
        if (eq(u8, kw, "interface")) return self.parseInterfaceDecl(line, col);
        if (eq(u8, kw, "enum")) return self.parseEnumDecl(line, col);
        // `const enum E { ... }` — TypeScript's inlined enum. Lumen already
        // inlines every enum member at its use site, so a const enum lowers
        // identically; just consume the `const` and parse the enum.
        if (eq(u8, kw, "const") and self.peekIsKw("enum")) {
            try self.advance(); // 'const'
            return self.parseEnumDecl(line, col);
        }
        if (eq(u8, kw, "extern")) return self.parseExternDecl(line, col);
        // `declare function NAME(...): R;` — the TypeScript-valid spelling for an
        // FFI declaration; identical lowering to `extern function`.
        if (eq(u8, kw, "declare")) return self.parseExternDecl(line, col);
        if (eq(u8, kw, "function")) return self.parseFunctionDecl(line, col, false);
        // `async function ...` — an asynchronous function returning a Promise<T>.
        if (eq(u8, kw, "async")) {
            try self.advance(); // 'async'
            if (!self.isKw("function")) return error.ParseError;
            return self.parseFunctionDecl(line, col, true);
        }
        if (eq(u8, kw, "switch")) return self.parseSwitch(line, col);
        if (eq(u8, kw, "class")) return self.parseClassDecl(line, col);
        if (eq(u8, kw, "abstract")) {
            self.last_err = "abstract classes are not supported yet — use an `interface` for the contract a subclass must implement, or a base class with concrete methods";
            return error.ParseError;
        }
        if (eq(u8, kw, "namespace") or eq(u8, kw, "module")) {
            self.last_err = "namespaces are not supported — organize code into files and use `import`/`export`";
            return error.ParseError;
        }

        // `this.field = value;` (member assignment) or `this.method(args);`
        if (eq(u8, kw, "this")) {
            try self.advance(); // 'this'
            try self.expectOp('.');
            if (self.cur != .ident) return error.ParseError;
            const member = self.cur.ident;
            try self.advance();
            if (self.isOp('(')) {
                try self.expectOp('(');
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try args.append(self.arena, try self.parseExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                try self.expectSemi();
                const this_e = try self.node(.this_expr);
                const mc = try self.node(.{ .method_call = .{ .obj = this_e, .name = member, .args = try args.toOwnedSlice(self.arena) } });
                return .{ .expr_stmt = .{ .value = mc, .line = line, .col = col } };
            }
            // A deeper chain off the field — `this.items.set(k, v);`,
            // `this.a.b.c = v;`, `this.arr[i] = v;` (spec 277). Build the
            // `this.member` field node and continue with postfix parsing.
            if (self.isOp('.') or self.isOp('[') or self.isOp2("?.")) {
                const this_e = try self.node(.this_expr);
                const base = try self.node(.{ .field = .{ .obj = this_e, .name = member } });
                const full = try self.parsePostfixFrom(base);
                return self.finishChainStmt(full, line, col);
            }
            // `this.x++;` / `this.x--;` as a statement — the postfix value is
            // discarded here, so lower to `this.x += 1` / `this.x -= 1`.
            if (self.cur == .op2 and (eq(u8, self.cur.op2, "++") or eq(u8, self.cur.op2, "--"))) {
                const is_inc = eq(u8, self.cur.op2, "++");
                try self.advance();
                try self.expectSemi();
                const one = try self.node(.{ .num = 1 });
                return .{ .member_assign = .{ .field = member, .op = if (is_inc) "+=" else "-=", .value = one, .line = line, .col = col } };
            }
            var op: []const u8 = "=";
            if (self.isOp('=')) {
                try self.advance();
            } else if (self.isCompoundAssignOp()) {
                op = self.cur.op2;
                try self.advance();
            } else return error.ParseError;
            const value = try self.parseExpr();
            try self.expectSemi();
            return .{ .member_assign = .{ .field = member, .op = op, .value = value, .line = line, .col = col } };
        }

        // `super(args);` (parent constructor) or `super.method(args);`.
        if (eq(u8, kw, "super")) {
            try self.advance(); // 'super'
            if (self.isOp('(')) {
                try self.expectOp('(');
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try args.append(self.arena, try self.parseExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                try self.expectSemi();
                return .{ .super_ctor = .{ .args = try args.toOwnedSlice(self.arena), .line = line, .col = col } };
            }
            try self.expectOp('.');
            if (self.cur != .ident) return error.ParseError;
            const member = self.cur.ident;
            try self.advance();
            try self.expectOp('(');
            var args: std.ArrayListUnmanaged(*Expr) = .empty;
            while (!self.isOp(')')) {
                try args.append(self.arena, try self.parseExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(')');
            try self.expectSemi();
            const sc = try self.node(.{ .super_call = .{ .name = member, .args = try args.toOwnedSlice(self.arena) } });
            return .{ .expr_stmt = .{ .value = sc, .line = line, .col = col } };
        }

        if (eq(u8, kw, "let") or eq(u8, kw, "const") or eq(u8, kw, "var")) {
            const mutable = eq(u8, kw, "let") or eq(u8, kw, "var");
            try self.advance();
            // Destructuring: `let [a, b] = e;` or `let { x, y } = e;`
            if (self.isOp('[') or self.isOp('{')) {
                const is_object = self.isOp('{');
                try self.advance();
                const close: u8 = if (is_object) '}' else ']';
                var bindings: std.ArrayListUnmanaged(ast.DestructBinding) = .empty;
                while (!self.isOp(close)) {
                    // Array rest element `[a, ...rest]` — binds the remainder.
                    const is_rest = !is_object and self.isSpread();
                    if (is_rest) try self.advance();
                    if (self.cur != .ident) return error.ParseError;
                    const first_name = self.cur.ident;
                    try self.advance();
                    // Object rename `{ field: local }` — the ident before `:` is
                    // the source field; the ident after it is the local binding.
                    if (is_object and self.isOp(':')) {
                        try self.advance();
                        if (self.cur != .ident) return error.ParseError;
                        const local = self.cur.ident;
                        try self.advance();
                        // Renamed object binding default `{ field: local = 1 }`.
                        var default_expr: ?*ast.Expr = null;
                        if (self.isOp('=')) {
                            try self.advance();
                            default_expr = try self.parseExpr();
                        }
                        try bindings.append(self.arena, .{ .name = local, .field_name = first_name, .default = default_expr });
                    } else {
                        // Element/property default: `[a = 1]` (array, used when the
                        // source is shorter) or `{ x = 1 }` (object, used when an
                        // optional property is absent).
                        var default_expr: ?*ast.Expr = null;
                        if (!is_rest and self.isOp('=')) {
                            try self.advance();
                            default_expr = try self.parseExpr();
                        }
                        try bindings.append(self.arena, .{ .name = first_name, .is_rest = is_rest, .default = default_expr });
                    }
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(close);
                try self.expectOp('=');
                const source = try self.parseExpr();
                try self.expectSemi();
                return .{ .destructure_decl = .{ .mutable = mutable, .is_object = is_object, .bindings = try bindings.toOwnedSlice(self.arena), .source = source, .line = line, .col = col } };
            }
            // One or more comma-separated declarators: `let a = 1, b = 2;`.
            var decls: std.ArrayListUnmanaged(ast.VarDecl) = .empty;
            while (true) {
                if (self.cur != .ident) return error.ParseError;
                const name = self.cur.ident;
                const dline = self.cur_line;
                const dcol = self.cur_col;
                try self.advance();
                var annotation: ?[]const u8 = null;
                if (self.isOp(':')) {
                    try self.advance();
                    annotation = try self.parseTypeAnnotation();
                }
                // `let x: T;` — a typed declaration with no initializer. Requires
                // an annotation (the type can't be inferred from nothing). A
                // throwaway `0` placeholder fills `init`; `no_init` drives emit.
                if (annotation != null and !self.isOp('=')) {
                    const placeholder = try self.node(.{ .num = 0 });
                    try decls.append(self.arena, .{ .mutable = mutable, .name = name, .annotation = annotation, .init = placeholder, .no_init = true, .line = dline, .col = dcol });
                    if (self.isOp(',')) {
                        try self.advance();
                        continue;
                    }
                    break;
                }
                try self.expectOp('=');
                const initial_value = try self.parseExpr();
                try decls.append(self.arena, .{ .mutable = mutable, .name = name, .annotation = annotation, .init = initial_value, .line = dline, .col = dcol });
                if (self.isOp(',')) {
                    try self.advance();
                    continue;
                }
                break;
            }
            try self.expectSemi();
            if (decls.items.len == 1) return .{ .var_decl = decls.items[0] };
            return .{ .var_decl_group = try decls.toOwnedSlice(self.arena) };
        }

        // `using NAME = EXPR;` — TypeScript 5.2 scope-exit disposal. Reuses the
        // same scope-exit (LIFO) lowering as `defer`. Disposes the bound value at
        // block/function exit; see ast.UsingDecl.
        if (eq(u8, kw, "using")) {
            try self.advance();
            if (self.cur != .ident) return error.ParseError;
            const name = self.cur.ident;
            try self.advance();
            var annotation: ?[]const u8 = null;
            if (self.isOp(':')) {
                try self.advance();
                annotation = try self.parseTypeAnnotation();
            }
            try self.expectOp('=');
            // `using x = defer(() => BODY);` — the built-in scope-exit helper. The
            // body is parsed as statements (so `console.log(...)` works) and run
            // at scope exit, exactly like the `defer` statement. We still build an
            // `init` call node for the checker to validate the helper shape.
            if (self.isKw("defer") and self.peekIsOpenParen()) {
                try self.advance(); // 'defer'
                try self.expectOp('(');
                if (!self.isOp('(')) return error.ParseError; // require `() =>`
                try self.advance();
                try self.expectOp(')');
                if (!self.isOp2("=>")) return error.ParseError;
                try self.advance();
                var defer_body: []Stmt = undefined;
                if (self.isOp('{')) {
                    // Block-bodied arrow: `defer(() => { ...; ... })`.
                    defer_body = try self.parseBlock();
                } else {
                    // Single-expression arrow body, followed by the `)` that closes
                    // the `defer(` call (so no trailing `;` to consume here).
                    const single = try self.arena.alloc(Stmt, 1);
                    single[0] = try self.parseDeferHelperBodyStmt();
                    defer_body = single;
                }
                try self.expectOp(')');
                try self.expectSemi();
                const init_call = try self.node(.{ .call = .{ .name = "defer", .args = &.{} } });
                return .{ .using_decl = .{ .name = name, .annotation = annotation, .init = init_call, .defer_body = defer_body, .line = line, .col = col } };
            }
            const initial_value = try self.parseExpr();
            try self.expectSemi();
            return .{ .using_decl = .{ .name = name, .annotation = annotation, .init = initial_value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "console")) {
            try self.advance();
            try self.expectOp('.');
            if (self.cur != .ident) return error.ParseError;
            const method = self.cur.ident;
            // The six single-`any`-arg print methods (spec 048) share one
            // dedicated ConsoleLog node: log/info/debug print to stdout,
            // error/warn print to stderr, trace prints to stderr prefixed
            // with "Trace: ". See lumen_emit_stmt.zig for the routing.
            if (eq(u8, method, "log") or eq(u8, method, "error") or eq(u8, method, "warn") or
                eq(u8, method, "info") or eq(u8, method, "debug") or eq(u8, method, "trace"))
            {
                try self.advance();
                try self.expectOp('(');
                const value = try self.parseExpr();
                var extra_values: std.ArrayListUnmanaged(*Expr) = .empty;
                while (self.isOp(',')) {
                    try self.advance();
                    try extra_values.append(self.arena, try self.parseExpr());
                }
                try self.expectOp(')');
                try self.expectSemi();
                return .{ .console_log = .{ .method = method, .value = value, .extra_values = try extra_values.toOwnedSlice(self.arena), .line = line, .col = col } };
            }
            self.last_err = "E_UNSUPPORTED_STD";
            return error.ParseError;
        }

        if (eq(u8, kw, "while")) {
            try self.advance();
            try self.expectOp('(');
            const cond = try self.parseExpr();
            try self.expectOp(')');
            const body = try self.parseBlockOrStmt();
            return .{ .while_stmt = .{ .cond = cond, .body = body, .line = line, .col = col } };
        }

        if (eq(u8, kw, "do")) {
            try self.advance();
            const body = try self.parseBlock();
            if (!self.isKw("while")) return error.ParseError;
            try self.advance();
            try self.expectOp('(');
            const cond = try self.parseExpr();
            try self.expectOp(')');
            try self.expectSemi();
            return .{ .do_while_stmt = .{ .body = body, .cond = cond, .line = line, .col = col } };
        }

        if (eq(u8, kw, "for")) {
            try self.advance();
            try self.expectOp('(');
            // C-style for with an omitted init clause: `for (; cond?; update?)`.
            if (self.isOp(';')) {
                try self.advance(); // past the first ';'
                const cond: ?*Expr = if (self.isOp(';')) null else try self.parseExpr();
                try self.expectOp(';');
                const ul = self.cur_line;
                const uc = self.cur_col;
                const update: ?ast.Assign = if (self.isOp(')')) null else if (self.cur == .op2 and (eq(u8, self.cur.op2, "++") or eq(u8, self.cur.op2, "--"))) blk: {
                    const op = self.cur.op2;
                    break :blk try self.parsePrefixUpdate(op, ul, uc, false);
                } else blk: {
                    if (self.cur != .ident) return error.ParseError;
                    const un = self.cur.ident;
                    try self.advance();
                    break :blk try self.parseAssignmentTail(un, ul, uc, false);
                };
                var extra_updates: std.ArrayListUnmanaged(ast.Assign) = .empty;
                while (self.isOp(',')) {
                    try self.advance();
                    const el = self.cur_line;
                    const ec = self.cur_col;
                    const u = if (self.cur == .op2 and (eq(u8, self.cur.op2, "++") or eq(u8, self.cur.op2, "--"))) blk2: {
                        const op = self.cur.op2;
                        break :blk2 try self.parsePrefixUpdate(op, el, ec, false);
                    } else blk2: {
                        if (self.cur != .ident) return error.ParseError;
                        const un = self.cur.ident;
                        try self.advance();
                        break :blk2 try self.parseAssignmentTail(un, el, ec, false);
                    };
                    try extra_updates.append(self.arena, u);
                }
                try self.expectOp(')');
                const body = try self.parseBlockOrStmt();
                return .{ .for_stmt = .{
                    .init = null,
                    .cond = cond,
                    .update = update,
                    .extra_updates = try extra_updates.toOwnedSlice(self.arena),
                    .body = body,
                    .line = line,
                    .col = col,
                } };
            }
            if (self.cur != .ident) return error.ParseError;
            const init_kw = self.cur.ident;
            const is_const = eq(u8, init_kw, "const");
            if (!eq(u8, init_kw, "let") and !eq(u8, init_kw, "var") and !is_const) return error.ParseError;
            try self.advance();
            // `for (const [k, v] of map)` — a pair-destructuring for-of binding.
            if (self.isOp('[')) {
                try self.advance();
                if (self.cur != .ident) return error.ParseError;
                const kname = self.cur.ident;
                try self.advance();
                try self.expectOp(',');
                if (self.cur != .ident) return error.ParseError;
                const vname = self.cur.ident;
                try self.advance();
                try self.expectOp(']');
                if (!self.isKw("of")) return error.ParseError;
                try self.advance();
                const iterable = try self.parseExpr();
                try self.expectOp(')');
                const body = try self.parseBlockOrStmt();
                return .{ .for_of_stmt = .{ .mutable = !is_const, .binding = kname, .is_pair = true, .value_binding = vname, .iterable = iterable, .body = body, .line = line, .col = col } };
            }
            // `for (const { a, b } of records)` — object-pattern for-of. Desugared
            // to a plain for-of over a fresh temp with an object destructuring
            // prepended to the body, reusing the existing object-destructure path.
            if (self.isOp('{')) {
                try self.advance();
                var fields: std.ArrayListUnmanaged([]const u8) = .empty;
                while (!self.isOp('}')) {
                    if (self.cur != .ident) return error.ParseError;
                    try fields.append(self.arena, self.cur.ident);
                    try self.advance();
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp('}');
                if (!self.isKw("of")) return error.ParseError;
                try self.advance();
                const iterable = try self.parseExpr();
                try self.expectOp(')');
                const inner_body = try self.parseBlockOrStmt();
                const tmp = try std.fmt.allocPrint(self.arena, "__lumen_fo_{d}_{d}", .{ line, col });
                const src_expr = try self.arena.create(Expr);
                src_expr.* = .{ .var_ref = .{ .name = tmp, .emit_name = tmp } };
                const binds = try self.arena.alloc(ast.DestructBinding, fields.items.len);
                for (fields.items, 0..) |f, i| binds[i] = .{ .name = f };
                const ds_stmt: Stmt = .{ .destructure_decl = .{ .mutable = !is_const, .is_object = true, .bindings = binds, .source = src_expr, .line = line, .col = col } };
                const new_body = try self.arena.alloc(Stmt, inner_body.len + 1);
                new_body[0] = ds_stmt;
                @memcpy(new_body[1..], inner_body);
                return .{ .for_of_stmt = .{ .mutable = false, .binding = tmp, .iterable = iterable, .body = new_body, .line = line, .col = col } };
            }
            if (self.cur != .ident) return error.ParseError;
            const init_name = self.cur.ident;
            const init_line = self.cur_line;
            const init_col = self.cur_col;
            try self.advance();
            // for...of: `for (const|let name of iterable) { ... }`
            if (self.isKw("of")) {
                try self.advance();
                const iterable = try self.parseExpr();
                try self.expectOp(')');
                const body = try self.parseBlockOrStmt();
                return .{ .for_of_stmt = .{ .mutable = !is_const, .binding = init_name, .iterable = iterable, .body = body, .line = line, .col = col } };
            }
            // for...in: `for (const|let name in x) { ... }` (spec 052) --
            // iterates a record's field names / an array's indices as strings.
            if (self.isKw("in")) {
                try self.advance();
                const iterable = try self.parseExpr();
                try self.expectOp(')');
                const body = try self.parseBlockOrStmt();
                return .{ .for_in_stmt = .{ .mutable = !is_const, .binding = init_name, .iterable = iterable, .body = body, .line = line, .col = col } };
            }
            // C-style for loops require a reassignable binding for the update step.
            if (is_const) return error.ParseError;
            var annotation: ?[]const u8 = null;
            if (self.isOp(':')) {
                try self.advance();
                annotation = try self.parseTypeAnnotation();
            }
            try self.expectOp('=');
            const init_value = try self.parseExpr();
            // Extra init declarators: `for (let i = 0, n = 5; ...)`.
            var extra_inits: std.ArrayListUnmanaged(ast.VarDecl) = .empty;
            while (self.isOp(',')) {
                try self.advance();
                if (self.cur != .ident) return error.ParseError;
                const en = self.cur.ident;
                const el = self.cur_line;
                const ec = self.cur_col;
                try self.advance();
                var eann: ?[]const u8 = null;
                if (self.isOp(':')) {
                    try self.advance();
                    eann = try self.parseTypeAnnotation();
                }
                try self.expectOp('=');
                const ev = try self.parseExpr();
                try extra_inits.append(self.arena, .{ .mutable = true, .name = en, .annotation = eann, .init = ev, .line = el, .col = ec });
            }
            try self.expectOp(';');
            // The condition may be omitted (`for (i; ; u)`) — an unconditional loop.
            const cond: ?*Expr = if (self.isOp(';')) null else try self.parseExpr();
            try self.expectOp(';');
            // The update may be omitted (`for (i; c; )`).
            const update_line = self.cur_line;
            const update_col = self.cur_col;
            const update: ?ast.Assign = if (self.isOp(')')) null else if (self.cur == .op2 and (std.mem.eql(u8, self.cur.op2, "++") or std.mem.eql(u8, self.cur.op2, "--"))) blk: {
                const op = self.cur.op2;
                break :blk try self.parsePrefixUpdate(op, update_line, update_col, false);
            } else blk: {
                if (self.cur != .ident) return error.ParseError;
                const update_name = self.cur.ident;
                try self.advance();
                break :blk try self.parseAssignmentTail(update_name, update_line, update_col, false);
            };
            // Extra updates: `for (...; ...; i++, j--)`.
            var extra_updates: std.ArrayListUnmanaged(ast.Assign) = .empty;
            while (self.isOp(',')) {
                try self.advance();
                const ul = self.cur_line;
                const uc = self.cur_col;
                const u = if (self.cur == .op2 and (std.mem.eql(u8, self.cur.op2, "++") or std.mem.eql(u8, self.cur.op2, "--"))) blk2: {
                    const op = self.cur.op2;
                    break :blk2 try self.parsePrefixUpdate(op, ul, uc, false);
                } else blk2: {
                    if (self.cur != .ident) return error.ParseError;
                    const un = self.cur.ident;
                    try self.advance();
                    break :blk2 try self.parseAssignmentTail(un, ul, uc, false);
                };
                try extra_updates.append(self.arena, u);
            }
            try self.expectOp(')');
            const body = try self.parseBlockOrStmt();
            return .{ .for_stmt = .{
                .init = .{ .mutable = true, .name = init_name, .annotation = annotation, .init = init_value, .line = init_line, .col = init_col },
                .extra_inits = try extra_inits.toOwnedSlice(self.arena),
                .cond = cond,
                .update = update,
                .extra_updates = try extra_updates.toOwnedSlice(self.arena),
                .body = body,
                .line = line,
                .col = col,
            } };
        }

        if (eq(u8, kw, "if")) {
            try self.advance();
            try self.expectOp('(');
            const cond = try self.parseExpr();
            try self.expectOp(')');
            const then_body = try self.parseBlockOrStmt();
            var else_body: ?[]Stmt = null;
            if (self.isKw("else")) {
                try self.advance();
                if (self.isKw("if")) {
                    const nested_if = try self.parseStmt();
                    const nested_body = try self.arena.alloc(Stmt, 1);
                    nested_body[0] = nested_if;
                    else_body = nested_body;
                } else {
                    else_body = try self.parseBlockOrStmt();
                }
            }
            return .{ .if_stmt = .{ .cond = cond, .then_body = then_body, .else_body = else_body, .line = line, .col = col } };
        }

        if (eq(u8, kw, "return")) {
            try self.advance();
            // Restricted production: a value must start on the `return` line
            // (`return\nx` returns void, matching JS ASI).
            const value = if (self.isOp(';') or self.isOp('}') or self.cur == .eof or self.cur_line > self.prev_line)
                null
            else
                try self.parseExpr();
            try self.expectSemi();
            return .{ .return_stmt = .{ .value = value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "break")) {
            try self.advance();
            // A label must sit on the same line (JS's restricted production):
            // `break\ncase 2:` inside a switch ends the statement at the
            // newline instead of eating `case` as a label.
            const lbl = if (self.cur == .ident and self.cur_line == self.prev_line) blk: {
                const n = self.cur.ident;
                try self.advance();
                break :blk n;
            } else null;
            try self.expectSemi();
            return .{ .break_stmt = .{ .label = lbl, .line = line, .col = col } };
        }

        if (eq(u8, kw, "continue")) {
            try self.advance();
            const lbl = if (self.cur == .ident and self.cur_line == self.prev_line) blk: {
                const n = self.cur.ident;
                try self.advance();
                break :blk n;
            } else null;
            try self.expectSemi();
            return .{ .continue_stmt = .{ .label = lbl, .line = line, .col = col } };
        }

        if (eq(u8, kw, "throw")) {
            try self.advance();
            const value = try self.parseExpr();
            try self.expectSemi();
            return .{ .throw_stmt = .{ .value = value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "defer")) {
            try self.advance();
            if (self.isOp('{')) {
                const body = try self.parseBlock();
                return .{ .defer_stmt = .{ .body = body, .line = line, .col = col } };
            }
            const single = try self.arena.alloc(Stmt, 1);
            single[0] = try self.parseStmt();
            return .{ .defer_stmt = .{ .body = single, .line = line, .col = col } };
        }

        if (eq(u8, kw, "try")) {
            try self.advance();
            const try_body = try self.parseBlock();
            // A `catch` clause is optional when a `finally` follows
            // (`try { ... } finally { ... }`); an uncaught throw runs finally
            // then re-propagates.
            var catch_name: ?[]const u8 = null;
            var catch_body: []Stmt = &.{};
            var has_catch = false;
            if (self.isKw("catch")) {
                has_catch = true;
                try self.advance();
                // Optional catch binding (spec 052): `catch { ... }` with no
                // `(e)` discards the error. `catch ()` (empty parens) stays a
                // parse error -- an opened paren must name a binding.
                if (self.isOp('(')) {
                    try self.advance();
                    if (self.cur != .ident) return error.ParseError;
                    catch_name = self.cur.ident;
                    try self.advance();
                    try self.expectOp(')');
                }
                catch_body = try self.parseBlock();
            } else if (!self.isKw("finally")) {
                return error.ParseError; // must have catch or finally
            }
            var finally_body: ?[]Stmt = null;
            if (self.isKw("finally")) {
                try self.advance();
                finally_body = try self.parseBlock();
            }
            return .{ .try_stmt = .{ .try_body = try_body, .catch_name = catch_name, .catch_body = catch_body, .has_catch = has_catch, .finally_body = finally_body, .line = line, .col = col } };
        }

        // Test declarations. Two surfaces lower to the same `test_decl`:
        //   * `test "name" { ... }`              — the original block form.
        //   * `test("name", () => { ... });`     — the conventional function form
        //                                          (Jest/Vitest/node:test style),
        //                                          which is valid TypeScript.
        // Both are recognised only by lookahead, so `test` stays usable as an
        // ordinary identifier everywhere else.
        if (eq(u8, kw, "test")) {
            const save_lex = self.lex;
            const save_cur = self.cur;
            const save_line = self.cur_line;
            const save_col = self.cur_col;
            self.advance() catch {};
            const after_test = self.cur;
            self.lex = save_lex;
            self.cur = save_cur;
            self.cur_line = save_line;
            self.cur_col = save_col;
            if (after_test == .str) {
                // `test "name" { ... }`
                try self.advance(); // 'test'
                const name = self.cur.str;
                try self.advance(); // name string
                const tbody = try self.parseBlock();
                return .{ .test_decl = .{ .name = name, .body = tbody, .line = line, .col = col } };
            }
            if (after_test == .op and after_test.op == '(') {
                // `test("name", () => { ... });`
                try self.advance(); // 'test'
                try self.expectOp('(');
                if (self.cur != .str) return error.ParseError;
                const name = self.cur.str;
                try self.advance(); // name string
                try self.expectOp(',');
                // Callback `() => { ... }`: no params, block body.
                try self.expectOp('(');
                try self.expectOp(')');
                if (!self.isOp2("=>")) return error.ParseError;
                try self.advance(); // '=>'
                const tbody = try self.parseBlock();
                try self.expectOp(')');
                try self.expectSemi();
                return .{ .test_decl = .{ .name = name, .body = tbody, .line = line, .col = col } };
            }
        }

        // `expect(...)` assertions. The boolean form `expect(cond);` and the
        // matcher form `expect(actual).toBe(expected);` (and `.toEqual`) both
        // lower to a single `expect` call node; the matcher carries the expected
        // value as a second argument and a marker name. Recognised only when an
        // open paren follows, so `expect` stays usable as an identifier.
        if (eq(u8, kw, "expect") and self.peekIsOpenParen()) {
            try self.advance(); // 'expect'
            try self.expectOp('(');
            const actual = try self.parseExpr();
            try self.expectOp(')');
            if (self.isOp('.')) {
                try self.advance(); // '.'
                if (self.cur != .ident) return error.ParseError;
                const matcher = self.cur.ident;
                const matcher_name: ?[]const u8 = if (eq(u8, matcher, "toBe"))
                    "__expectToBe"
                else if (eq(u8, matcher, "toEqual"))
                    "__expectToEqual"
                else
                    null;
                if (matcher_name == null) {
                    self.last_err = "E_UNKNOWN_MATCHER";
                    return error.ParseError;
                }
                try self.advance(); // matcher name
                try self.expectOp('(');
                const expected = try self.parseExpr();
                try self.expectOp(')');
                try self.expectSemi();
                const args = try self.arena.alloc(*Expr, 2);
                args[0] = actual;
                args[1] = expected;
                const value = try self.node(.{ .call = .{ .name = matcher_name.?, .args = args } });
                return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
            }
            // Boolean form: `expect(cond);`.
            try self.expectSemi();
            const args = try self.arena.alloc(*Expr, 1);
            args[0] = actual;
            const value = try self.node(.{ .call = .{ .name = "expect", .args = args } });
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }

        if (isBuiltin(kw)) {
            const value = try self.parseExpr();
            try self.expectSemi();
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }

        const name = kw;
        const save_before_name = self.lex;
        const save_cur_name = self.cur;
        const save_line_name = self.cur_line;
        const save_col_name = self.cur_col;
        try self.advance();
        if (self.isOp('(')) {
            try self.expectOp('(');
            var args: std.ArrayListUnmanaged(*Expr) = .empty;
            while (!self.isOp(')')) {
                try args.append(self.arena, try self.parseSpreadOrExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(')');
            // A method call on a returned object, e.g. `make().go();`, continues
            // as a postfix expression statement.
            if (self.isOp('.') or self.isOp('[') or self.isOp2("?.")) {
                const call_e = try self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena) } });
                const e = try self.parsePostfixFrom(call_e);
                return self.finishChainStmt(e, line, col);
            }
            try self.expectSemi();
            const value = try self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena) } });
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }
        // Single-level member assignment: `obj.field = value;`,
        // `Class.staticField += value;`, or a setter property write.
        if (self.isOp('.')) {
            const save_lex = self.lex;
            const save_cur = self.cur;
            try self.advance(); // '.'
            if (self.cur == .ident) {
                const field = self.cur.ident;
                try self.advance();
                var op: []const u8 = "=";
                var is_assign = false;
                if (self.isOp('=')) {
                    is_assign = true;
                    try self.advance();
                } else if (self.isCompoundAssignOp()) {
                    is_assign = true;
                    op = self.cur.op2;
                    try self.advance();
                }
                if (is_assign) {
                    const obj = try self.node(.{ .var_ref = .{ .name = name } });
                    const value = try self.parseExpr();
                    try self.expectSemi();
                    return .{ .member_assign = .{ .field = field, .op = op, .value = value, .obj = obj, .line = line, .col = col } };
                }
            }
            // Not a simple assignment: restore and fall through to postfix.
            self.lex = save_lex;
            self.cur = save_cur;
        }
        // Member-expression statement: `obj.method(args);`, `obj.field...`,
        // possibly continuing into an operator (`a.length > 2 ? ... : ...;`).
        // Restore to the identifier and parse the full expression.
        if (self.isOp('.') or self.isOp('[') or self.isOp2("?.")) {
            self.lex = save_before_name;
            self.cur = save_cur_name;
            self.cur_line = save_line_name;
            self.cur_col = save_col_name;
            const value = try self.parseExpr();
            return self.finishChainStmt(value, line, col);
        }
        // An assignment (`x = ...`, `x += ...`, `x++`) or, failing that, a
        // general expression statement led by an identifier (`x > 0 ? a : b;`,
        // `x + y;`). Restore to the identifier and parse the whole expression.
        if (self.isOp('=') or self.isCompoundAssignOp() or
            (self.cur == .op2 and (std.mem.eql(u8, self.cur.op2, "++") or std.mem.eql(u8, self.cur.op2, "--"))))
        {
            return .{ .assign = try self.parseAssignmentTail(name, line, col, true) };
        }
        self.lex = save_before_name;
        self.cur = save_cur_name;
        self.cur_line = save_line_name;
        self.cur_col = save_col_name;
        const value = try self.parseExpr();
        try self.expectSemi();
        return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
    }

    /// Completes a statement whose target has already been parsed through its
    /// postfix chain (`a.b`, `a[i].b`, `a.b[i].c`, `this.items[i].f`, ...).
    /// A trailing `=` or compound-assign operator makes the statement a field
    /// write, so the chain has to end in a plain (non-optional) field access:
    /// `f() = 5`, `a.b() = 5` and `a?.b = 5` are not assignable and are
    /// reported as such. Without a trailing assignment operator the chain is
    /// just an expression statement.
    fn finishChainStmt(self: *Parser, full: *Expr, line: u32, col: u32) CompileError!Stmt {
        if (self.isOp('=') or self.isCompoundAssignOp()) {
            // A chain ending in an index is a write into the container itself,
            // which stays rejected for the same reason `a[i] = v` is: arrays and
            // records are immutable. Report it the same way, so `a[i][j] = v`
            // and `a[i] = v` do not explain themselves differently.
            if (full.* == .index) {
                self.last_err = "indexed assignment (`x[i] = ...`) is not supported — arrays and records are immutable; build a new value instead (e.g. `a = [...a.slice(0, i), v, ...a.slice(i + 1)]`)";
                return error.ParseError;
            }
            if (full.* != .field or full.field.optional_chain) {
                self.last_err = "invalid assignment target — only a variable or a field reached through a chain of fields and indexes (`a.b`, `a[i].b`, `a.b[i].c`) can be assigned to";
                return error.ParseError;
            }
            var op: []const u8 = "=";
            if (self.isOp('=')) {
                try self.advance();
            } else {
                op = self.cur.op2;
                try self.advance();
            }
            const value = try self.parseExpr();
            try self.expectSemi();
            return .{ .member_assign = .{ .field = full.field.name, .op = op, .value = value, .obj = full.field.obj, .line = line, .col = col } };
        }
        try self.expectSemi();
        return .{ .expr_stmt = .{ .value = full, .line = line, .col = col } };
    }

    pub fn parseProgram(self: *Parser) CompileError!Program {
        var stmts: std.ArrayListUnmanaged(Stmt) = .empty;
        while (self.cur != .eof) try stmts.append(self.arena, try self.parseStmt());
        return .{ .stmts = try stmts.toOwnedSlice(self.arena) };
    }
};

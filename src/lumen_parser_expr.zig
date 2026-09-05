//! Type-annotation and expression parsing.
//!
//! Type annotations are kept as raw source-text strings on the AST (resolved
//! later by the checker), so `parseTypeAnnotation`/`parseFunctionType`/
//! `parseTupleType`/`parseTypeMember` mostly scan and slice rather than build
//! structure. Expression parsing is a standard precedence-climbing cascade
//! (`parseTernary` -> `parseCoalesce` -> `parseOr` -> ... -> `parseUnary` ->
//! `parsePostfix` -> `parsePrimary`), each level handling one precedence tier
//! and falling through to the next for anything it does not recognize.
//!
//! Pulled out of `lumen_parser.zig` as the "parsing a value" concern, distinct
//! from statement and declaration parsing (which call into this for every
//! expression they contain).

const std = @import("std");
const ast = @import("lumen_ast.zig");
const lexer = @import("lumen_lexer.zig");
const diag_mod = @import("lumen_diag.zig");
const parser_mod = @import("lumen_parser.zig");

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const FieldInit = ast.FieldInit;
const Parser = parser_mod.Parser;

pub fn parseTypeMember(self: *Parser) CompileError![]const u8 {
    const kw = std.mem.eql;
    // `keyof P` — handled here (not only in parseTypeAnnotation) so it also works
    // in a bare alias RHS (`type K = keyof P`) which reads members directly.
    if (self.cur == .ident and kw(u8, self.cur.ident, "keyof")) {
        const save = self.lex;
        const save_cur = self.cur;
        try self.advance();
        if (self.cur == .ident) {
            const operand = try self.parseTypeMember();
            return std.fmt.allocPrint(self.arena, "keyof {s}", .{operand}) catch error.OutOfMemory;
        }
        self.lex = save;
        self.cur = save_cur;
    }
    // A string-literal member type, e.g. a discriminant field `kind: "circle"`.
    // The annotation is recorded with quotes preserved so the checker can
    // recognize and compare the literal value.
    if (self.cur == .str) {
        const lit = std.fmt.allocPrint(self.arena, "\"{s}\"", .{self.cur.str}) catch return error.OutOfMemory;
        try self.advance();
        return lit;
    }
    if (self.cur != .ident) return error.ParseError;
    var base = self.cur.ident;
    try self.advance();
    // Generic type reference `Name<arg, ...>`. `Array<X>` is sugar for `X[]`;
    // any other `Name<...>` is recorded canonically for the checker to
    // specialize. (Nested `Name<Inner<...>>` is supported via recursion.)
    if (self.isCmp("<")) {
        try self.advance(); // '<'
        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        while (!self.isCmp(">")) {
            try args.append(self.arena, try self.parseTypeAnnotation());
            if (self.isOp(',')) try self.advance() else break;
        }
        try self.consumeTypeArgClose();
        if (std.mem.eql(u8, base, "Array") or std.mem.eql(u8, base, "ReadonlyArray")) {
            // `Array<X>` and `ReadonlyArray<X>` both desugar to `X[]`.
            // `readonly` is a compile-time immutability marker with no
            // runtime representation here (spec 052), so the two collapse
            // to the same lowered type.
            if (args.items.len != 1) return error.ParseError;
            base = std.fmt.allocPrint(self.arena, "{s}[]", .{args.items[0]}) catch return error.OutOfMemory;
        } else {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.appendSlice(self.arena, base);
            try buf.append(self.arena, '<');
            for (args.items, 0..) |a, i| {
                if (i > 0) try buf.append(self.arena, ',');
                try buf.appendSlice(self.arena, a);
            }
            try buf.append(self.arena, '>');
            base = buf.items;
        }
    }
    // One or more `[]` suffixes: `T[]`, `T[][]`, ... (nested arrays, spec 289),
    // or an indexed-access type `P["field"]` (spec 379).
    while (self.isOp('[')) {
        try self.advance();
        if (self.cur == .str) {
            const field = self.cur.str;
            try self.advance();
            try self.expectOp(']');
            base = std.fmt.allocPrint(self.arena, "{s}[\"{s}\"]", .{ base, field }) catch return error.OutOfMemory;
        } else if (self.cur == .ident) {
            // `P[K]` — an indexed access keyed by a mapped-type variable, kept
            // verbatim for the mapped-type expansion to substitute (spec 381).
            const key = self.cur.ident;
            try self.advance();
            try self.expectOp(']');
            base = std.fmt.allocPrint(self.arena, "{s}[{s}]", .{ base, key }) catch return error.OutOfMemory;
        } else {
            try self.expectOp(']');
            base = std.fmt.allocPrint(self.arena, "{s}[]", .{base}) catch return error.OutOfMemory;
        }
    }
    return base;
}

/// Consumes the `>` (or one level of a `>>` produced by nested type args)
/// that closes a type-argument list inside an annotation.
pub fn consumeTypeArgClose(self: *Parser) CompileError!void {
    if (self.isCmp(">")) {
        try self.advance();
        return;
    }
    // A trailing `>>` from `Outer<Inner<X>>` lexes as one op2 token; rewrite
    // it to a single `>` so the enclosing level can consume its own close.
    if (self.isOp2(">>")) {
        self.cur = .{ .cmp = ">" };
        return;
    }
    // `Map<K, V>=` (a generic field/var type immediately before an initializer)
    // lexes the `>=` as one comparison token; split off the `=` initializer.
    if (self.isCmp(">=")) {
        self.cur = .{ .op = '=' };
        return;
    }
    // `Outer<Inner<X>>=` lexes the `>>=` as one op2 token; leave `>=` for the
    // enclosing level to split.
    if (self.isOp2(">>=")) {
        self.cur = .{ .cmp = ">=" };
        return;
    }
    return error.ParseError;
}

/// Parses a type annotation. `T | null` / `T | undefined` (in either order)
/// produce the canonical optional spelling `T?`; other `|` unions are
/// deferred to a later milestone.
/// Function type annotation `(name: T, ...) => R`, encoded canonically as
/// `(T,...)=>R` for the checker to parse.
pub fn parseFunctionType(self: *Parser) CompileError![]const u8 {
    try self.expectOp('(');
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(self.arena, '(');
    var first = true;
    while (!self.isOp(')')) {
        if (self.cur != .ident) return error.ParseError;
        try self.advance(); // param name
        try self.expectOp(':');
        const pty = try self.parseTypeAnnotation();
        if (!first) try buf.append(self.arena, ',');
        try buf.appendSlice(self.arena, pty);
        first = false;
        if (self.isOp(',')) try self.advance() else break;
    }
    try self.expectOp(')');
    if (!self.isOp2("=>")) return error.ParseError;
    try self.advance();
    const ret = try self.parseTypeAnnotation();
    try buf.appendSlice(self.arena, ")=>");
    try buf.appendSlice(self.arena, ret);
    return buf.items;
}

/// Tuple type annotation `[A, B, ...]`, encoded canonically as `[A,B,...]`
/// for the checker to parse.
pub fn parseTupleType(self: *Parser) CompileError![]const u8 {
    try self.expectOp('[');
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(self.arena, '[');
    var first = true;
    while (!self.isOp(']')) {
        const elem = try self.parseTypeAnnotation();
        if (!first) try buf.append(self.arena, ',');
        try buf.appendSlice(self.arena, elem);
        first = false;
        if (self.isOp(',')) try self.advance() else break;
    }
    try self.expectOp(']');
    if (first) return error.ParseError; // `[]` is not a tuple
    try buf.append(self.arena, ']');
    // Tuple arrays `[A, B][]` (spec 291): append each `[]` suffix.
    while (self.isOp('[')) {
        try self.advance();
        try self.expectOp(']');
        try buf.appendSlice(self.arena, "[]");
    }
    return buf.items;
}

pub fn parseTypeAnnotation(self: *Parser) CompileError![]const u8 {
    const eq = std.mem.eql;
    // A leading `readonly` modifier (`readonly int[]`, `readonly [A, B]`,
    // `readonly string[]`) is a compile-time immutability marker with no
    // runtime representation (spec 052) -- strip it and parse the underlying
    // type. `readonly` is not a lexer keyword, so it arrives as a plain
    // ident; only strip it when a type genuinely follows (a `(`/`[`/ident),
    // never when `readonly` is itself the whole annotation.
    if (self.cur == .ident and eq(u8, self.cur.ident, "readonly")) {
        const save = self.lex;
        const save_cur = self.cur;
        try self.advance();
        if (self.isOp('(') or self.isOp('[') or self.cur == .ident) {
            // fall through with `readonly` consumed
        } else {
            self.lex = save; // `readonly` was actually the type name; restore
            self.cur = save_cur;
        }
    }
    if (self.isOp('(')) {
        // Disambiguate a function type `(a: T) => R` from a parenthesized type
        // `(T | null)[]` (spec 296): try the function form; on failure, restore
        // and parse the parenthesized type, honoring a trailing `[]` suffix.
        const save_lex = self.lex;
        const save_cur = self.cur;
        const save_line = self.cur_line;
        const save_col = self.cur_col;
        const save_prev = self.prev_line;
        if (self.parseFunctionType()) |ft| {
            return ft;
        } else |_| {
            self.lex = save_lex;
            self.cur = save_cur;
            self.cur_line = save_line;
            self.cur_col = save_col;
            self.prev_line = save_prev;
            try self.advance(); // '('
            var inner = try self.parseTypeAnnotation();
            try self.expectOp(')');
            if (self.isOp('[')) {
                // Preserve the grouping parens so `((i32)=>i32)[]` (array of
                // functions) stays distinct from `(i32)=>i32[]` (function
                // returning an array) in the annotation string (spec 297).
                inner = std.fmt.allocPrint(self.arena, "({s})", .{inner}) catch return error.OutOfMemory;
                while (self.isOp('[')) {
                    try self.advance();
                    try self.expectOp(']');
                    inner = std.fmt.allocPrint(self.arena, "{s}[]", .{inner}) catch return error.OutOfMemory;
                }
            }
            // A trailing `| null` / `| undefined` makes it optional (spec 298),
            // e.g. `((x: i32) => i32) | null`. Parenthesize the element before
            // the `?` so `((i32)=>i32)?` (optional function) stays distinct from
            // `(i32)=>i32?` (function returning an optional).
            var optional = false;
            while (self.isCmp("|")) {
                try self.advance();
                if (self.cur != .ident) return error.ParseError;
                const member = self.cur.ident;
                try self.advance();
                if (!eq(u8, member, "null") and !eq(u8, member, "undefined")) return error.ParseError;
                optional = true;
            }
            if (optional) inner = std.fmt.allocPrint(self.arena, "({s})?", .{inner}) catch return error.OutOfMemory;
            return inner;
        }
    }
    if (self.isOp('[')) return self.parseTupleType();
    if (self.isOp('{')) {
        self.last_err = "inline object types are not supported — declare a named type (`type T = { ... }`) and use its name";
        return error.ParseError;
    }
    var base = try self.parseTypeMember();
    var optional = false;
    while (self.isCmp("|")) {
        try self.advance();
        const member = try self.parseTypeMember();
        if (eq(u8, member, "null") or eq(u8, member, "undefined")) {
            optional = true;
        } else if (eq(u8, base, "null") or eq(u8, base, "undefined")) {
            base = member;
            optional = true;
        } else if (base.len > 0 and base[0] == '"' and member.len > 0 and member[0] == '"') {
            // A union of string literals (`"a" | "b"`) — kept as a joined
            // annotation string for the checker (e.g. a `Pick`/`Omit` key set).
            base = std.fmt.allocPrint(self.arena, "{s}|{s}", .{ base, member }) catch return error.OutOfMemory;
        } else {
            // General unions (`i32 | string`) aren't supported inline; only
            // `T | null` and named discriminated unions (`type U = A | B` over
            // record types with a shared literal tag).
            self.last_err = "only `T | null` and discriminated record unions are supported — for a mix of shapes, declare `type U = A | B` over named record types with a shared literal tag";
            return error.ParseError;
        }
    }
    if (optional) return std.fmt.allocPrint(self.arena, "{s}?", .{base}) catch error.OutOfMemory;
    return base;
}

pub fn parseExpr(self: *Parser) CompileError!*Expr {
    return self.parseTernary();
}

/// Parses one array-literal element or call argument, recognizing a leading
/// `...` spread (`...expr`) and wrapping it in a `spread` node.
pub fn parseSpreadOrExpr(self: *Parser) CompileError!*Expr {
    if (self.isSpread()) {
        try self.advance();
        const inner = try self.parseExpr();
        return self.node(.{ .spread = inner });
    }
    return self.parseExpr();
}

/// Splits a template literal's raw inner text into literal-text and `${expr}`
/// parts, sub-parsing each hole as an expression. `tmpl_line`/`tmpl_col` locate
/// the opening backtick (`raw[0]` is the byte after it), so diagnostics the
/// hole sub-parsers raise can be placed in the outer source.
pub fn parseTemplateParts(self: *Parser, raw: []const u8, tmpl_line: u32, tmpl_col: u32) CompileError![]ast.TemplatePart {
    var parts: std.ArrayListUnmanaged(ast.TemplatePart) = .empty;
    var i: usize = 0;
    var text_start: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 2;
            continue;
        }
        if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
            if (i > text_start) try parts.append(self.arena, .{ .text = raw[text_start..i] });
            i += 2;
            const hole_start = i;
            var depth: u32 = 1;
            while (i < raw.len and depth > 0) {
                if (raw[i] == '{') {
                    depth += 1;
                } else if (raw[i] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                i += 1;
            }
            const hole = raw[hole_start..i];
            if (i < raw.len) i += 1; // skip closing '}'
            text_start = i;
            var sub = try Parser.init(self.arena, hole);
            const parsed = sub.parseExpr();
            // A `"..."` literal inside the hole warns like one anywhere else
            // (spec 502, FR-001): the sub-parser's warnings are adopted, with
            // their hole-relative positions moved onto the outer source, and
            // whether or not the hole parsed, as the compiler does for the
            // whole program.
            try adoptHoleWarnings(self, &sub, raw, hole_start, tmpl_line, tmpl_col);
            try parts.append(self.arena, .{ .expr = try parsed });
        } else {
            i += 1;
        }
    }
    if (raw.len > text_start) try parts.append(self.arena, .{ .text = raw[text_start..] });
    return parts.toOwnedSlice(self.arena);
}

/// Appends the warnings a template-hole sub-parser raised to the outer
/// parser's list, translating each position from the hole's own coordinates
/// (line 1, column 1 is the hole's first byte) to the outer source's. The hole
/// is `raw[hole_start..]`, and `raw[0]` is the byte after the opening backtick
/// at (`tmpl_line`, `tmpl_col`). Nested templates compose: an inner hole's
/// warning is first moved onto its enclosing hole, then onto the source.
fn adoptHoleWarnings(self: *Parser, sub: *const Parser, raw: []const u8, hole_start: usize, tmpl_line: u32, tmpl_col: u32) CompileError!void {
    if (sub.warnings.items.len == 0) return;
    // Source line and column of the hole's first byte.
    const prefix = raw[0..hole_start];
    var line = tmpl_line;
    var col: u32 = tmpl_col + 1 + @as(u32, @intCast(hole_start));
    if (std.mem.lastIndexOfScalar(u8, prefix, '\n')) |nl| {
        line += @intCast(std.mem.count(u8, prefix, "\n"));
        col = @intCast(hole_start - nl);
    }
    for (sub.warnings.items) |w| {
        try self.warnings.append(self.arena, .{
            .line = line + (w.line - 1),
            .col = if (w.line == 1) col + (w.col - 1) else w.col,
            .msg = w.msg,
            .extra = w.extra,
        });
    }
}
pub fn parseTernary(self: *Parser) CompileError!*Expr {
    const cond = try self.parseCoalesce();
    if (!self.isOp('?')) return cond;
    try self.advance();
    const then_expr = try self.parseExpr();
    try self.expectOp(':');
    const else_expr = try self.parseExpr();
    return self.node(.{ .ternary = .{ .cond = cond, .then_expr = then_expr, .else_expr = else_expr } });
}
pub fn parseCoalesce(self: *Parser) CompileError!*Expr {
    var left = try self.parseOr();
    while (self.isOp2("??")) {
        try self.advance();
        const right = try self.parseOr();
        left = try self.node(.{ .coalesce = .{ .l = left, .r = right } });
    }
    return left;
}
pub fn isCmp(self: *Parser, op: []const u8) bool {
    return self.cur == .cmp and std.mem.eql(u8, self.cur.cmp, op);
}
pub fn isComparison(self: *Parser) bool {
    if (self.cur != .cmp) return false;
    const op = self.cur.cmp;
    return std.mem.eql(u8, op, "<") or
        std.mem.eql(u8, op, ">") or
        std.mem.eql(u8, op, "<=") or
        std.mem.eql(u8, op, ">=") or
        std.mem.eql(u8, op, "==") or
        std.mem.eql(u8, op, "!=");
}
pub fn parseOr(self: *Parser) CompileError!*Expr {
    var left = try self.parseAnd();
    while (self.isCmp("||")) {
        const op = self.cur.cmp;
        try self.advance();
        const right = try self.parseAnd();
        left = try self.node(.{ .bool_bin = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseAnd(self: *Parser) CompileError!*Expr {
    var left = try self.parseBitOr();
    while (self.isCmp("&&")) {
        const op = self.cur.cmp;
        try self.advance();
        const right = try self.parseBitOr();
        left = try self.node(.{ .bool_bin = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseBitOr(self: *Parser) CompileError!*Expr {
    var left = try self.parseBitXor();
    while (self.isCmp("|")) {
        try self.advance();
        const right = try self.parseBitXor();
        left = try self.node(.{ .bin = .{ .op = '|', .l = left, .r = right } });
    }
    return left;
}
pub fn parseBitXor(self: *Parser) CompileError!*Expr {
    var left = try self.parseBitAnd();
    while (self.isOp('^')) {
        try self.advance();
        const right = try self.parseBitAnd();
        left = try self.node(.{ .bin = .{ .op = '^', .l = left, .r = right } });
    }
    return left;
}
pub fn parseBitAnd(self: *Parser) CompileError!*Expr {
    var left = try self.parseCmp();
    while (self.isOp('&')) {
        try self.advance();
        const right = try self.parseCmp();
        left = try self.node(.{ .bin = .{ .op = '&', .l = left, .r = right } });
    }
    return left;
}
/// Equality (`== !=`) binds looser than relational (`< > <= >=`), matching JS,
/// so `5 > 3 == true` parses as `(5 > 3) == true`. Equality chains left-assoc.
pub fn parseCmp(self: *Parser) CompileError!*Expr {
    var left = try self.parseRelational();
    while (self.cur == .cmp and (std.mem.eql(u8, self.cur.cmp, "==") or std.mem.eql(u8, self.cur.cmp, "!="))) {
        const op = self.cur.cmp;
        try self.advance();
        const right = try self.parseRelational();
        left = try self.node(.{ .cmp = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseRelational(self: *Parser) CompileError!*Expr {
    var left = try self.parseShift();
    // `x instanceof ClassName` -> bool (spec 292). The right side is a class
    // name, not an expression.
    if (self.isKw("instanceof")) {
        try self.advance();
        if (self.cur != .ident) return error.ParseError;
        const cname = self.cur.ident;
        try self.advance();
        return self.node(.{ .instanceof_expr = .{ .value = left, .class_name = cname } });
    }
    if (self.cur == .cmp and (std.mem.eql(u8, self.cur.cmp, "<") or std.mem.eql(u8, self.cur.cmp, ">") or
        std.mem.eql(u8, self.cur.cmp, "<=") or std.mem.eql(u8, self.cur.cmp, ">=")))
    {
        const op = self.cur.cmp;
        try self.advance();
        const right = try self.parseShift();
        left = try self.node(.{ .cmp = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseShift(self: *Parser) CompileError!*Expr {
    var left = try self.parseAdd();
    while (self.isOp2("<<") or self.isOp2(">>")) {
        const op: u8 = if (self.isOp2("<<")) 'L' else 'R';
        try self.advance();
        const right = try self.parseAdd();
        left = try self.node(.{ .bin = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseAdd(self: *Parser) CompileError!*Expr {
    var left = try self.parseMul();
    while (self.isOp('+') or self.isOp('-')) {
        const op = self.cur.op;
        try self.advance();
        const right = try self.parseMul();
        left = try self.node(.{ .bin = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseMul(self: *Parser) CompileError!*Expr {
    var left = try self.parseExp();
    while (self.isOp('*') or self.isOp('/') or self.isOp('%')) {
        const op = self.cur.op;
        try self.advance();
        const right = try self.parseExp();
        left = try self.node(.{ .bin = .{ .op = op, .l = left, .r = right } });
    }
    return left;
}
pub fn parseExp(self: *Parser) CompileError!*Expr {
    const left = try self.parseUnary();
    if (self.isOp2("**")) {
        try self.advance();
        const right = try self.parseExp(); // right-associative
        return self.node(.{ .bin = .{ .op = 'P', .l = left, .r = right } });
    }
    return left;
}
pub fn parseUnary(self: *Parser) CompileError!*Expr {
    // `await <expr>` — the operand is a Promise; yields the resolved value.
    if (self.isKw("await")) {
        try self.advance();
        return self.node(.{ .await_expr = try self.parseUnary() });
    }
    if (self.isOp('-')) {
        try self.advance();
        return self.node(.{ .neg = try self.parseUnary() });
    }
    // Unary plus `+x` — JS coerces the operand to a number. On a numeric
    // operand this is the identity; on a string (`+"42"`) it parses to a number.
    // Lower to `Number(x)`, which the checker resolves to identity for numeric
    // operands and to a string→number conversion otherwise (spec 305/406).
    if (self.isOp('+')) {
        try self.advance();
        const operand = try self.parseUnary();
        const args = self.arena.alloc(*Expr, 1) catch return error.OutOfMemory;
        args[0] = operand;
        return self.node(.{ .call = .{ .name = "Number", .args = args, .is_global_parse = true } });
    }
    if (self.isOp('!')) {
        try self.advance();
        return self.node(.{ .not = try self.parseUnary() });
    }
    if (self.isKw("typeof")) {
        try self.advance();
        return self.node(.{ .typeof_expr = .{ .operand = try self.parseUnary() } });
    }
    if (self.isOp('~')) {
        try self.advance();
        return self.node(.{ .bnot = try self.parseUnary() });
    }
    // Prefix increment/decrement `++x` / `--x` as an expression value.
    if (self.cur == .op2 and (std.mem.eql(u8, self.cur.op2, "++") or std.mem.eql(u8, self.cur.op2, "--"))) {
        const is_inc = std.mem.eql(u8, self.cur.op2, "++");
        try self.advance();
        return self.node(.{ .inc_dec = .{ .target = try self.parseUnary(), .is_inc = is_inc, .is_prefix = true } });
    }
    var e = try self.parsePostfix();
    // Postfix `as T` type assertion and `satisfies T` (spec 052), both
    // erased at emit; the checker distinguishes them (satisfies keeps the
    // operand's own type instead of widening to T).
    while (self.isKw("as") or self.isKw("satisfies")) {
        const is_satisfies = self.isKw("satisfies");
        try self.advance();
        const annotation = try self.parseTypeAnnotation();
        e = try self.node(.{ .cast = .{ .inner = e, .annotation = annotation, .is_satisfies = is_satisfies } });
    }
    return e;
}
pub fn parsePostfix(self: *Parser) CompileError!*Expr {
    return self.parsePostfixFrom(try self.parsePrimary());
}
pub fn parsePostfixFrom(self: *Parser, base: *Expr) CompileError!*Expr {
    var e = base;
    while (self.isOp('.') or self.isOp('[') or self.isOp2("?.") or self.isOp('(') or self.isOp('!')) {
        // Postfix non-null assertion `x!` (a single `!`, not `!=`/`!==`): unwraps
        // an optional. Chains with the other postfix forms (`a!.b`, `a.b!`).
        if (self.isOp('!')) {
            try self.advance();
            e = try self.node(.{ .non_null = .{ .inner = e } });
            continue;
        }
        // A direct call on a computed function value: `fns[0](5)`, `adder()(9)`,
        // `obj.field(x)` where the field is a function (spec 298). Reuses the
        // `optional_call` node with the chain flag off.
        if (self.isOp('(')) {
            try self.advance();
            var call_args: std.ArrayListUnmanaged(*Expr) = .empty;
            while (!self.isOp(')')) {
                try call_args.append(self.arena, try self.parseSpreadOrExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(')');
            e = try self.node(.{ .optional_call = .{ .callee = e, .args = try call_args.toOwnedSlice(self.arena), .optional_chain = false } });
            continue;
        }
        if (self.isOp2("?.")) {
            try self.advance();
            // Optional index `a?.[i]` (spec 052).
            if (self.isOp('[')) {
                try self.advance();
                const index_value = try self.parseExpr();
                try self.expectOp(']');
                e = try self.node(.{ .index = .{ .obj = e, .value = index_value, .optional_chain = true } });
                continue;
            }
            // Optional call `a?.()` (spec 062) -- calling the expression
            // built up so far directly, no name involved. Checked before the
            // ident-only guard so `(` doesn't require a preceding method name.
            if (self.isOp('(')) {
                try self.expectOp('(');
                var call_args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try call_args.append(self.arena, try self.parseSpreadOrExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                e = try self.node(.{ .optional_call = .{ .callee = e, .args = try call_args.toOwnedSlice(self.arena), .optional_chain = true } });
                continue;
            }
            if (self.cur != .ident) return error.ParseError;
            const name = self.cur.ident;
            try self.advance();
            // Optional method call `a?.b(args)` (spec 052). `a?.()` (an
            // optional call on the value itself, no name) is handled above,
            // before this ident guard (spec 062).
            if (self.isOp('(')) {
                try self.expectOp('(');
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try args.append(self.arena, try self.parseSpreadOrExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                e = try self.node(.{ .method_call = .{ .obj = e, .name = name, .args = try args.toOwnedSlice(self.arena), .optional_chain = true } });
                continue;
            }
            e = try self.node(.{ .field = .{ .obj = e, .name = name, .optional_chain = true } });
        } else if (self.isOp('.')) {
            try self.advance();
            if (self.cur != .ident) return error.ParseError;
            const name = self.cur.ident;
            try self.advance();
            // Explicit generic namespace call `Namespace.method<T>(...)`
            // (JSON.parse<T> is the first of these -- see spec 051). Only
            // treated as type arguments when a `(` provably follows the
            // matching `>`, the same guard the free-function `f<T>(...)`
            // parse site uses.
            var static_type_args: [][]const u8 = &.{};
            if (self.isCmp("<") and self.looksLikeTypeArgs()) {
                static_type_args = try self.parseTypeArgs();
            }
            if (self.isOp('(')) {
                try self.expectOp('(');
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try args.append(self.arena, try self.parseSpreadOrExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                if (e.* == .var_ref and Parser.isStdNamespace(e.var_ref.name)) {
                    e = try self.node(.{ .static_call = .{ .namespace = e.var_ref.name, .name = name, .args = try args.toOwnedSlice(self.arena), .type_args = static_type_args } });
                } else {
                    // instance method call: obj.method(args)
                    e = try self.node(.{ .method_call = .{ .obj = e, .name = name, .args = try args.toOwnedSlice(self.arena) } });
                }
            } else {
                e = try self.node(.{ .field = .{ .obj = e, .name = name } });
            }
        } else {
            try self.advance();
            const index_value = try self.parseExpr();
            try self.expectOp(']');
            e = try self.node(.{ .index = .{ .obj = e, .value = index_value } });
        }
    }
    // Postfix increment/decrement `x++` / `x--` as an expression value.
    if (self.cur == .op2 and (std.mem.eql(u8, self.cur.op2, "++") or std.mem.eql(u8, self.cur.op2, "--"))) {
        const is_inc = std.mem.eql(u8, self.cur.op2, "++");
        try self.advance();
        e = try self.node(.{ .inc_dec = .{ .target = e, .is_inc = is_inc, .is_prefix = false } });
    }
    return e;
}
/// Lookahead: is the `(` at `cur` the start of an arrow function? Scans to
/// the matching `)` and checks for a following `=>`, restoring parser state.
pub fn looksLikeArrow(self: *Parser) bool {
    const save_lex = self.lex;
    const save_cur = self.cur;
    const save_line = self.cur_line;
    const save_col = self.cur_col;
    defer {
        self.lex = save_lex;
        self.cur = save_cur;
        self.cur_line = save_line;
        self.cur_col = save_col;
    }
    self.advance() catch return false; // consume '('
    var depth: u32 = 1;
    while (depth > 0) {
        if (self.cur == .eof) return false;
        if (self.isOp('(')) depth += 1;
        if (self.isOp(')')) depth -= 1;
        self.advance() catch return false;
    }
    // An optional return-type annotation `): R =>` precedes the arrow.
    if (self.isOp(':')) {
        self.advance() catch return false;
        _ = self.parseTypeAnnotation() catch return false;
    }
    return self.isOp2("=>");
}

/// `(x: T, ...) [: R] => expr` — typed params, expression body, no capture.
pub fn parseArrow(self: *Parser) CompileError!*Expr {
    try self.expectOp('(');
    var params: std.ArrayListUnmanaged(ast.FunctionParam) = .empty;
    while (!self.isOp(')')) {
        if (self.cur != .ident) return error.ParseError;
        const pname = self.cur.ident;
        try self.advance();
        // The type annotation is optional: an untyped param (`(v) => ...`)
        // infers its type from the call's expected callback signature.
        var annotation: []const u8 = "";
        if (self.isOp(':')) {
            try self.advance();
            annotation = try self.parseTypeAnnotation();
        }
        try params.append(self.arena, .{ .name = pname, .annotation = annotation });
        if (self.isOp(',')) try self.advance() else break;
    }
    try self.expectOp(')');
    var ret_annotation: []const u8 = "";
    if (self.isOp(':')) {
        try self.advance();
        ret_annotation = try self.parseTypeAnnotation();
    }
    if (!self.isOp2("=>")) return error.ParseError;
    try self.advance();
    const arrow = try self.arena.create(ast.ArrowExpr);
    if (self.isOp('{')) {
        // Statement-body arrow `(...) => { ... }` (a void body).
        const block = try self.parseBlock();
        arrow.* = .{ .params = try params.toOwnedSlice(self.arena), .return_annotation = ret_annotation, .body_block = block };
    } else {
        const body_expr = try self.parseExpr();
        arrow.* = .{ .params = try params.toOwnedSlice(self.arena), .return_annotation = ret_annotation, .body_expr = body_expr };
    }
    return self.node(.{ .arrow = arrow });
}

/// Parse the single-expression body of a `defer(() => BODY)` helper. Unlike a
/// normal statement, the body is followed by `)` (not `;`), so no trailing
/// semicolon is consumed. `console.log(...)`/`console.error(...)`/`.warn(...)`/
/// `.info(...)`/`.debug(...)`/`.trace(...)` are recognized as console_log
/// statements (they have no expression form); any other expression becomes
/// an expression statement.
pub fn parseDeferHelperBodyStmt(self: *Parser) CompileError!Stmt {
    const line = self.cur_line;
    const col = self.cur_col;
    if (self.isKw("console")) {
        try self.advance();
        try self.expectOp('.');
        if (self.cur != .ident) return error.ParseError;
        const method = self.cur.ident;
        const eq = std.mem.eql;
        if (!eq(u8, method, "log") and !eq(u8, method, "error") and !eq(u8, method, "warn") and
            !eq(u8, method, "info") and !eq(u8, method, "debug") and !eq(u8, method, "trace"))
        {
            self.last_err = "E_UNSUPPORTED_STD";
            return error.ParseError;
        }
        try self.advance();
        try self.expectOp('(');
        const value = try self.parseExpr();
        try self.expectOp(')');
        return .{ .console_log = .{ .method = method, .value = value, .line = line, .col = col } };
    }
    const value = try self.parseExpr();
    return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
}

pub fn parsePrimary(self: *Parser) CompileError!*Expr {
    if (self.cur == .num) {
        const v = self.cur.num;
        try self.advance();
        return self.node(.{ .num = v });
    }
    if (self.cur == .flt) {
        const v = self.cur.flt;
        try self.advance();
        return self.node(.{ .float = v });
    }
    if (self.cur == .regex) {
        const rx = self.cur.regex;
        try self.advance();
        return self.node(.{ .regex = .{ .source = rx.pattern, .flags = rx.flags } });
    }
    if (self.isKw("true") or self.isKw("false")) {
        const v = self.isKw("true");
        try self.advance();
        return self.node(.{ .bool = v });
    }
    if (self.isKw("null") or self.isKw("undefined")) {
        try self.advance();
        return self.node(.null_lit);
    }
    if (self.isKw("this")) {
        try self.advance();
        return self.node(.this_expr);
    }
    if (self.isKw("super")) {
        try self.advance();
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
        return self.node(.{ .super_call = .{ .name = member, .args = try args.toOwnedSlice(self.arena) } });
    }
    if (self.isKw("new")) {
        try self.advance();
        if (self.cur != .ident) return error.ParseError;
        const class_name = self.cur.ident;
        try self.advance();
        var type_args: [][]const u8 = &.{};
        if (self.isCmp("<")) type_args = try self.parseTypeArgs();
        try self.expectOp('(');
        var args: std.ArrayListUnmanaged(*Expr) = .empty;
        while (!self.isOp(')')) {
            try args.append(self.arena, try self.parseSpreadOrExpr());
            if (self.isOp(',')) try self.advance() else break;
        }
        try self.expectOp(')');
        return self.node(.{ .new_expr = .{ .class_name = class_name, .args = try args.toOwnedSlice(self.arena), .type_args = type_args } });
    }
    if (self.cur == .template) {
        const raw = self.cur.template;
        const line = self.cur_line;
        const col = self.cur_col;
        try self.advance();
        return self.node(.{ .template = try self.parseTemplateParts(raw, line, col) });
    }
    if (self.cur == .str) {
        const s = self.cur.str;
        try self.advance();
        return self.node(.{ .str = s });
    }
    if (self.cur == .ident) {
        const name = self.cur.ident;
        try self.advance();
        // Bare single-parameter arrow `v => expr` (no parens, untyped). The
        // param type is inferred from the call's expected callback signature.
        if (self.isOp2("=>")) {
            try self.advance();
            const ps = try self.arena.alloc(ast.FunctionParam, 1);
            ps[0] = .{ .name = name, .annotation = "" };
            const arrow = try self.arena.create(ast.ArrowExpr);
            if (self.isOp('{')) {
                arrow.* = .{ .params = ps, .return_annotation = "", .body_block = try self.parseBlock() };
            } else {
                arrow.* = .{ .params = ps, .return_annotation = "", .body_expr = try self.parseExpr() };
            }
            return self.node(.{ .arrow = arrow });
        }
        // Explicit generic call `f<T, ...>(...)`. Only treated as type
        // arguments when a `(` provably follows the matching `>`.
        var type_args: [][]const u8 = &.{};
        if (self.isCmp("<") and self.looksLikeTypeArgs()) {
            type_args = try self.parseTypeArgs();
        }
        if (self.isOp('(')) {
            try self.expectOp('(');
            var args: std.ArrayListUnmanaged(*Expr) = .empty;
            while (!self.isOp(')')) {
                try args.append(self.arena, try self.parseSpreadOrExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(')');
            return self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena), .type_args = type_args } });
        }
        return self.node(.{ .var_ref = .{ .name = name } });
    }
    if (self.isOp('(') and self.looksLikeArrow()) {
        return self.parseArrow();
    }
    if (self.isOp('(')) {
        try self.advance();
        const e = try self.parseExpr();
        try self.expectOp(')');
        return e;
    }
    if (self.isOp('[')) {
        try self.advance();
        var items: std.ArrayListUnmanaged(*Expr) = .empty;
        while (!self.isOp(']')) {
            try items.append(self.arena, try self.parseSpreadOrExpr());
            if (self.isOp(',')) try self.advance() else break;
        }
        try self.expectOp(']');
        return self.node(.{ .array = .{ .items = try items.toOwnedSlice(self.arena) } });
    }
    if (self.isOp('{')) {
        try self.advance();
        var fields: std.ArrayListUnmanaged(FieldInit) = .empty;
        while (!self.isOp('}')) {
            // Object spread `...src` copies fields from another record.
            if (self.isSpread()) {
                try self.advance();
                const src = try self.parseExpr();
                try fields.append(self.arena, .{ .name = "", .value = src, .is_spread = true });
                if (self.isOp(',')) try self.advance() else break;
                continue;
            }
            // Static computed key `["literal"]: v` (spec 052). Only a
            // string-literal key is allowed -- a closed record shape has no
            // room for a dynamic (runtime-`expr`) key, so `{ [k]: v }` with
            // a non-literal key is a deliberate parse error.
            if (self.isOp('[')) {
                try self.advance();
                if (self.cur != .str) return error.ParseError;
                const key = self.cur.str;
                try self.advance();
                try self.expectOp(']');
                try self.expectOp(':');
                const cv = try self.parseExpr();
                try fields.append(self.arena, .{ .name = key, .value = cv });
                if (self.isOp(',')) try self.advance() else break;
                continue;
            }
            if (self.cur != .ident) return error.ParseError;
            const fname = self.cur.ident;
            try self.advance();
            // Method shorthand `{ run() { ... } }` desugars to a function-typed
            // field `run: (...) => { ... }`. (Object literals have no `this`, so
            // such a method is a plain closure over its params.)
            if (self.isOp('(')) {
                const params = try self.parseParamList();
                var ret_ann: []const u8 = "";
                if (self.isOp(':')) {
                    try self.advance();
                    ret_ann = try self.parseTypeAnnotation();
                }
                const block = try self.parseBlock();
                const arrow = try self.arena.create(ast.ArrowExpr);
                arrow.* = .{ .params = params, .return_annotation = ret_ann, .body_block = block };
                const av = try self.node(.{ .arrow = arrow });
                try fields.append(self.arena, .{ .name = fname, .value = av });
                if (self.isOp(',')) try self.advance() else break;
                continue;
            }
            // Shorthand `{ x }` (spec 052): no `: value` follows, so `x`
            // desugars to `x: x` -- a reference to the same-named binding.
            if (!self.isOp(':')) {
                const ref = try self.node(.{ .var_ref = .{ .name = fname } });
                try fields.append(self.arena, .{ .name = fname, .value = ref });
                if (self.isOp(',')) try self.advance() else break;
                continue;
            }
            try self.expectOp(':');
            const v = try self.parseExpr();
            try fields.append(self.arena, .{ .name = fname, .value = v });
            if (self.isOp(',')) try self.advance() else break;
        }
        try self.expectOp('}');
        return self.node(.{ .obj = try fields.toOwnedSlice(self.arena) });
    }
    return error.ParseError;
}

/// True when the current token is a compound-assignment operator: the
/// original arithmetic set (`+= -= *= /= %=`) plus the spec-052 additions
/// (logical `&&= ||= ??=`, bitwise `&= |= ^=`, shift `<<= >>=`, exponent
/// `**=`). The op string flows verbatim to `Assign.op`; the checker and
/// emitter interpret it.
pub fn isCompoundAssignOp(self: *Parser) bool {
    if (self.cur != .op2) return false;
    const s = self.cur.op2;
    const eq = std.mem.eql;
    return eq(u8, s, "+=") or eq(u8, s, "-=") or eq(u8, s, "*=") or eq(u8, s, "/=") or eq(u8, s, "%=") or
        eq(u8, s, "**=") or eq(u8, s, "&&=") or eq(u8, s, "||=") or eq(u8, s, "??=") or
        eq(u8, s, "&=") or eq(u8, s, "|=") or eq(u8, s, "^=") or eq(u8, s, "<<=") or eq(u8, s, ">>=");
}

pub fn parseAssignmentTail(self: *Parser, name: []const u8, line: u32, col: u32, needs_semicolon: bool) CompileError!ast.Assign {
    if (self.isOp('=')) {
        try self.advance();
        const value = try self.parseExpr();
        if (needs_semicolon) try self.expectSemi();
        return .{ .name = name, .op = "=", .value = value, .line = line, .col = col };
    }
    if (self.isCompoundAssignOp()) {
        const op = self.cur.op2;
        try self.advance();
        const value = try self.parseExpr();
        if (needs_semicolon) try self.expectSemi();
        return .{ .name = name, .op = op, .value = value, .line = line, .col = col };
    }
    if (self.isOp2("++") or self.isOp2("--")) {
        const op = self.cur.op2;
        try self.advance();
        if (needs_semicolon) try self.expectSemi();
        return .{ .name = name, .op = if (std.mem.eql(u8, op, "++")) "+=" else "-=", .value = try self.oneExpr(1), .line = line, .col = col };
    }
    return error.ParseError;
}

pub fn parsePrefixUpdate(self: *Parser, op: []const u8, line: u32, col: u32, needs_semicolon: bool) CompileError!ast.Assign {
    try self.advance();
    if (self.cur != .ident) return error.ParseError;
    const name = self.cur.ident;
    try self.advance();
    if (needs_semicolon) try self.expectSemi();
    return .{ .name = name, .op = if (std.mem.eql(u8, op, "++")) "+=" else "-=", .value = try self.oneExpr(1), .line = line, .col = col };
}

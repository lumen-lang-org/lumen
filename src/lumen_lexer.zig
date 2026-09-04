//! The lexer (tokenizer) -- stage 1 of the compiler.
//!
//! Turns raw `.ts` source bytes into a stream of `Tok` values that the parser in
//! `lumen_compiler.zig` pulls one at a time via `Lexer.next()`. It is a small,
//! hand-written scanner with only a few characters of lookahead.
//!
//! The one genuinely tricky thing it does: a leading `/` is ambiguous between
//! *division* and the start of a *regex literal*. It is resolved exactly the way
//! JavaScript does -- by remembering the previous significant token in `prev`. A
//! `/` after a value (number, identifier, `)`, `]`, postfix `++`/`--`) is
//! division; a `/` where an expression is expected starts a regex literal. See
//! `regexStartAllowed` and `lexRegex`.

const std = @import("std");
const diag = @import("lumen_diag.zig");

/// A regular-expression literal: the body between the slashes and the trailing
/// flag letters (e.g. `/ab+c/gi` -> pattern "ab+c", flags "gi").
pub const Regex = struct { pattern: []const u8, flags: []const u8 };

pub const Tok = union(enum) {
    num: i64,
    flt: f64, // floating-point literal (e.g. 3.14, 1.5e-2)
    str: []const u8, // string literal content (raw, between quotes)
    template: []const u8, // template literal raw content (between backticks)
    regex: Regex, // regular-expression literal `/pattern/flags`
    op: u8, // + - * / % ! ? ( ) { } ; , . : =
    op2: []const u8, // ++ -- += -= *= /= %= **= &&= ||= ??= &= |= ^= <<= >>= ** << >> ?? ?. =>
    op3: []const u8, // ... (spread/rest)
    cmp: []const u8, // < > <= >= == != && ||
    ident: []const u8,
    eof,
};

pub const Lexer = struct {
    src: []const u8,
    i: usize = 0,
    line: u32 = 1, // current source line
    line_start: usize = 0, // byte index where the current line begins (for column math)
    tok_line: u32 = 1, // line where the most-recently-returned token starts
    tok_col: u32 = 1, // column where that token starts (1-based)
    err_code: ?[]const u8 = null, // diagnostic code for the last lexer error
    tok_start: usize = 0, // byte offset where the most-recently-returned token starts
    str_raw_newline: bool = false, // the most-recently-returned `.str` token contains a raw `\n`/`\r` (spec 502)
    prev: ?Tok = null, // last significant token returned (for `/` regex disambiguation)

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
    }
    fn isIdentPart(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }
    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }
    fn isHexDigit(c: u8) bool {
        return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    /// Whether a `/` at the current position should start a regex literal rather
    /// than be a division operator. A regex is allowed at expression-start
    /// positions: at the very start, or after an operator/punctuator or a keyword
    /// that expects an expression next. After a value (number, string, identifier,
    /// `)`, `]`, postfix `++`/`--`) a `/` means division.
    fn regexStartAllowed(prev: ?Tok) bool {
        const p = prev orelse return true;
        return switch (p) {
            .num, .flt, .str, .template, .regex => false,
            .ident => |id| isRegexKeyword(id),
            .op => |ch| ch != ')' and ch != ']',
            .op2 => |s| !std.mem.eql(u8, s, "++") and !std.mem.eql(u8, s, "--"),
            .op3, .cmp => true,
            .eof => true,
        };
    }

    fn isRegexKeyword(id: []const u8) bool {
        const kws = [_][]const u8{ "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await" };
        for (kws) |kw| if (std.mem.eql(u8, kw, id)) return true;
        return false;
    }

    /// Scans `/pattern/flags` once the opening `/` is known to start a regex.
    /// `/` inside a `[...]` class or after `\` does not terminate the body.
    fn lexRegex(self: *Lexer) diag.CompileError!Tok {
        self.i += 1; // consume opening '/'
        const start = self.i;
        var in_class = false;
        while (self.i < self.src.len) {
            const ch = self.src[self.i];
            if (ch == '\\' and self.i + 1 < self.src.len) {
                self.i += 2;
                continue;
            }
            if (ch == '\n') {
                self.err_code = "E_UNTERMINATED_REGEX";
                return error.ParseError;
            }
            if (ch == '[') {
                in_class = true;
            } else if (ch == ']') {
                in_class = false;
            } else if (ch == '/' and !in_class) {
                break;
            }
            self.i += 1;
        }
        if (self.i >= self.src.len or self.src[self.i] != '/') {
            self.err_code = "E_UNTERMINATED_REGEX";
            return error.ParseError;
        }
        const pattern = self.src[start..self.i];
        self.i += 1; // consume closing '/'
        const flags_start = self.i;
        while (self.i < self.src.len and isIdentPart(self.src[self.i])) self.i += 1;
        const flags = self.src[flags_start..self.i];
        return .{ .regex = .{ .pattern = pattern, .flags = flags } };
    }

    pub fn next(self: *Lexer) diag.CompileError!Tok {
        const t = try self.nextInner();
        self.prev = t;
        return t;
    }

    /// Scan a `"..."` or `'...'` literal whose opening quote is at `self.i`.
    /// The body is kept raw (escapes are decoded by the emitter). A raw line
    /// break inside the body is accepted — the native target always has — but
    /// TypeScript rejects it, so the token is flagged through `str_raw_newline`
    /// and the parser reports `W_STRING_NEWLINE` (spec 502). Line tracking
    /// advances across the body, so every position after the literal stays
    /// correct.
    fn scanQuoted(self: *Lexer, quote: u8) Tok {
        self.i += 1;
        const start = self.i;
        while (self.i < self.src.len and self.src[self.i] != quote) {
            const ch = self.src[self.i];
            if (ch == '\\' and self.i + 1 < self.src.len) {
                self.i += 1;
                if (self.src[self.i] == '\n') {
                    // Backslash-newline: TypeScript reads it as a line
                    // continuation (no character), Lumen keeps the newline.
                    // The spelling is not portable either way, so it is
                    // flagged too; the line count must advance regardless.
                    self.str_raw_newline = true;
                    self.line += 1;
                    self.line_start = self.i + 1;
                } else if (self.src[self.i] == '\r') {
                    self.str_raw_newline = true;
                }
            } else if (ch == '\n') {
                self.str_raw_newline = true;
                self.line += 1;
                self.line_start = self.i + 1;
            } else if (ch == '\r') {
                self.str_raw_newline = true;
            }
            self.i += 1;
        }
        const s = self.src[start..self.i];
        if (self.i < self.src.len) self.i += 1; // closing quote
        return .{ .str = s };
    }

    fn nextInner(self: *Lexer) diag.CompileError!Tok {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '\n') {
                self.line += 1;
                self.i += 1;
                self.line_start = self.i;
                continue;
            }
            if (c == ' ' or c == '\t' or c == '\r') {
                self.i += 1;
                continue;
            }
            if (c == '/' and self.i + 1 < self.src.len and self.src[self.i + 1] == '/') {
                while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
                continue;
            }
            if (c == '/' and self.i + 1 < self.src.len and self.src[self.i + 1] == '*') {
                self.i += 2;
                while (self.i + 1 < self.src.len and !(self.src[self.i] == '*' and self.src[self.i + 1] == '/')) {
                    if (self.src[self.i] == '\n') {
                        self.line += 1;
                        self.line_start = self.i + 1;
                    }
                    self.i += 1;
                }
                if (self.i + 1 >= self.src.len) {
                    self.err_code = "E_UNTERMINATED_COMMENT";
                    return error.ParseError;
                }
                self.i += 2; // consume the closing */
                continue;
            }
            break;
        }
        self.tok_line = self.line;
        self.tok_col = @intCast(self.i - self.line_start + 1);
        self.tok_start = self.i;
        self.str_raw_newline = false;
        if (self.i >= self.src.len) return .eof;
        const c = self.src[self.i];

        // A regex literal takes priority over `/=` and `/` division, but only at
        // positions where an expression (a value) is expected, not after one.
        if (c == '/' and regexStartAllowed(self.prev)) return self.lexRegex();

        if (c == '|') {
            if (self.i + 1 < self.src.len and self.src[self.i + 1] == c) {
                // `||=` logical-assignment (spec 052) -- longest match first.
                if (self.i + 2 < self.src.len and self.src[self.i + 2] == '=') {
                    const s = self.src[self.i .. self.i + 3];
                    self.i += 3;
                    return .{ .op2 = s };
                }
                const s = self.src[self.i .. self.i + 2];
                self.i += 2;
                return .{ .cmp = s };
            }
            if (self.i + 1 < self.src.len and self.src[self.i + 1] == '=') {
                const s = self.src[self.i .. self.i + 2]; // `|=` bitwise-or assign
                self.i += 2;
                return .{ .op2 = s };
            }
            const s = self.src[self.i .. self.i + 1];
            self.i += 1;
            return .{ .cmp = s };
        }
        if (c == '&') {
            if (self.i + 1 < self.src.len and self.src[self.i + 1] == '&') {
                // `&&=` logical-assignment (spec 052) -- longest match first.
                if (self.i + 2 < self.src.len and self.src[self.i + 2] == '=') {
                    const s = self.src[self.i .. self.i + 3];
                    self.i += 3;
                    return .{ .op2 = s };
                }
                const s = self.src[self.i .. self.i + 2];
                self.i += 2;
                return .{ .cmp = s };
            }
            if (self.i + 1 < self.src.len and self.src[self.i + 1] == '=') {
                const s = self.src[self.i .. self.i + 2]; // `&=` bitwise-and assign
                self.i += 2;
                return .{ .op2 = s };
            }
            self.i += 1;
            return .{ .op = '&' }; // bitwise and
        }
        if ((c == '+' or c == '-' or c == '*' or c == '/' or c == '%') and self.i + 1 < self.src.len and self.src[self.i + 1] == '=') {
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .op2 = s };
        }
        if ((c == '+' or c == '-') and self.i + 1 < self.src.len and self.src[self.i + 1] == c) {
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .op2 = s };
        }
        // `**` exponent and `<<`/`>>` shifts are two-char operator tokens;
        // `**=`/`<<=`/`>>=` (spec 052) are their three-char assignment forms.
        if (c == '*' and self.i + 1 < self.src.len and self.src[self.i + 1] == '*') {
            if (self.i + 2 < self.src.len and self.src[self.i + 2] == '=') {
                const s = self.src[self.i .. self.i + 3];
                self.i += 3;
                return .{ .op2 = s };
            }
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .op2 = s };
        }
        if ((c == '<' or c == '>') and self.i + 1 < self.src.len and self.src[self.i + 1] == c) {
            if (self.i + 2 < self.src.len and self.src[self.i + 2] == '=') {
                const s = self.src[self.i .. self.i + 3];
                self.i += 3;
                return .{ .op2 = s };
            }
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .op2 = s };
        }
        // `^=` bitwise-xor assignment (spec 052); plain `^` falls to the
        // single-char catch-all below.
        if (c == '^' and self.i + 1 < self.src.len and self.src[self.i + 1] == '=') {
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .op2 = s };
        }
        // `??` nullish coalescing, `??=` nullish-assignment (spec 052), and
        // `?.` optional chaining.
        if (c == '?' and self.i + 1 < self.src.len and (self.src[self.i + 1] == '?' or self.src[self.i + 1] == '.')) {
            if (self.src[self.i + 1] == '?' and self.i + 2 < self.src.len and self.src[self.i + 2] == '=') {
                const s = self.src[self.i .. self.i + 3];
                self.i += 3;
                return .{ .op2 = s };
            }
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .op2 = s };
        }
        // `=>` arrow (function types and arrow functions).
        if (c == '=' and self.i + 1 < self.src.len and self.src[self.i + 1] == '>') {
            const s = self.src[self.i .. self.i + 2];
            self.i += 2;
            return .{ .op2 = s };
        }
        if (c == '<' or c == '>' or c == '=' or c == '!') {
            const two = self.i + 1 < self.src.len and self.src[self.i + 1] == '=';
            if (c == '=' and !two) {
                self.i += 1;
                return .{ .op = '=' };
            }
            if (c == '!' and !two) {
                self.i += 1;
                return .{ .op = '!' };
            }
            // Strict equality `===`/`!==` lowers to the same comparison as `==`/`!=`;
            // statically typed operands make loose and strict equality identical.
            if ((c == '=' or c == '!') and two and self.i + 2 < self.src.len and self.src[self.i + 2] == '=') {
                self.i += 3;
                return .{ .cmp = if (c == '=') "==" else "!=" };
            }
            if (two) {
                const s = self.src[self.i .. self.i + 2];
                self.i += 2;
                return .{ .cmp = s };
            }
            const s = self.src[self.i .. self.i + 1];
            self.i += 1;
            return .{ .cmp = s };
        }
        // `"..."` and `'...'` (spec 274) share one scanner.
        if (c == '"' or c == '\'') return self.scanQuoted(c);
        if (c == '`') {
            self.i += 1;
            const start = self.i;
            // Scan to the matching closing backtick, treating `${...}` as an
            // interpolation whose contents (nested braces, strings, and nested
            // template literals) do not close the outer template (spec 300).
            const end = templateBodyEnd(self.src, self.i);
            const s = self.src[start..end];
            // Advance line tracking across the whole body.
            var k = self.i;
            while (k < end) : (k += 1) {
                if (self.src[k] == '\n') {
                    self.line += 1;
                    self.line_start = k + 1;
                }
            }
            self.i = end;
            if (self.i < self.src.len) self.i += 1; // closing backtick
            return .{ .template = s };
        }
        // `...` spread/rest operator (three dots).
        if (c == '.' and self.i + 2 < self.src.len and self.src[self.i + 1] == '.' and self.src[self.i + 2] == '.') {
            const s = self.src[self.i .. self.i + 3];
            self.i += 3;
            return .{ .op3 = s };
        }
        // `@` starts a decorator (spec 455). It has no other meaning in the
        // language, so it is a plain single-character operator token and the
        // parser decides where one may appear.
        switch (c) {
            '+', '-', '*', '/', '%', '?', '(', ')', '[', ']', ';', ',', '.', ':', '{', '}', '^', '~', '@' => {
                self.i += 1;
                return .{ .op = c };
            },
            else => {},
        }
        if (isDigit(c)) {
            const start = self.i;
            // Non-decimal integer bases: 0x / 0o / 0b. `parseInt(_, _, 0)` detects
            // the base from the prefix and accepts `_` digit separators.
            if (c == '0' and self.i + 1 < self.src.len) {
                const p = self.src[self.i + 1];
                if (p == 'x' or p == 'X' or p == 'o' or p == 'O' or p == 'b' or p == 'B') {
                    self.i += 2;
                    const digits_start = self.i;
                    while (self.i < self.src.len and (isHexDigit(self.src[self.i]) or self.src[self.i] == '_')) self.i += 1;
                    if (self.i == digits_start) {
                        self.err_code = "E_INVALID_NUMBER";
                        return error.ParseError;
                    }
                    const text = self.src[start..self.i];
                    const v = std.fmt.parseInt(i64, text, 0) catch {
                        self.err_code = "E_INVALID_NUMBER";
                        return error.ParseError;
                    };
                    return .{ .num = v };
                }
            }
            // Decimal integer or float. `_` separators are permitted between digits;
            // `parseInt`/`parseFloat` validate separator placement.
            var is_float = false;
            while (self.i < self.src.len and (isDigit(self.src[self.i]) or self.src[self.i] == '_')) self.i += 1;
            // fractional part: only treat `.` as a decimal point when a digit follows,
            // so member access like `arr.length` is untouched.
            if (self.i + 1 < self.src.len and self.src[self.i] == '.' and isDigit(self.src[self.i + 1])) {
                is_float = true;
                self.i += 1; // consume '.'
                while (self.i < self.src.len and (isDigit(self.src[self.i]) or self.src[self.i] == '_')) self.i += 1;
            }
            // exponent part
            if (self.i < self.src.len and (self.src[self.i] == 'e' or self.src[self.i] == 'E')) {
                is_float = true;
                self.i += 1;
                if (self.i < self.src.len and (self.src[self.i] == '+' or self.src[self.i] == '-')) self.i += 1;
                while (self.i < self.src.len and (isDigit(self.src[self.i]) or self.src[self.i] == '_')) self.i += 1;
            }
            const text = self.src[start..self.i];
            if (is_float) {
                const f = std.fmt.parseFloat(f64, text) catch {
                    self.err_code = "E_INVALID_NUMBER";
                    return error.ParseError;
                };
                return .{ .flt = f };
            }
            const v = std.fmt.parseInt(i64, text, 10) catch {
                self.err_code = "E_INVALID_NUMBER";
                return error.ParseError;
            };
            // BigInt literal suffix `100n`: consume the `n`. Lumen's integer
            // literal is already an i64 (which backs `bigint`), so the value is
            // unchanged — the suffix is just accepted and dropped.
            if (self.i < self.src.len and self.src[self.i] == 'n') self.i += 1;
            return .{ .num = v };
        }
        if (isIdentStart(c)) {
            const start = self.i;
            while (self.i < self.src.len and isIdentPart(self.src[self.i])) self.i += 1;
            return .{ .ident = self.src[start..self.i] };
        }
        // `#name` ECMAScript private field (spec 052): lexed as a single ident
        // whose text includes the leading `#`, so `#x` and `x` stay distinct.
        if (c == '#' and self.i + 1 < self.src.len and isIdentStart(self.src[self.i + 1])) {
            const start = self.i;
            self.i += 1; // consume '#'
            while (self.i < self.src.len and isIdentPart(self.src[self.i])) self.i += 1;
            return .{ .ident = self.src[start..self.i] };
        }
        return error.ParseError;
    }
};

/// Returns the index of the closing backtick of a template whose body starts at
/// `start` (just after the opening backtick), treating `${...}` interpolations
/// as opaque — nested braces, string literals, and nested template literals
/// inside them do not close the outer template (spec 300).
fn templateBodyEnd(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\' and i + 1 < src.len) {
            i += 2;
            continue;
        }
        if (c == '`') return i;
        if (c == '$' and i + 1 < src.len and src[i + 1] == '{') {
            i = skipInterp(src, i + 2);
            continue;
        }
        i += 1;
    }
    return i;
}

/// Given `i` positioned just after a `${`, returns the index just after the
/// matching `}`, skipping nested braces, quoted strings, and nested templates.
fn skipInterp(src: []const u8, i_in: usize) usize {
    var i = i_in;
    var depth: usize = 1;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\' and i + 1 < src.len) {
            i += 2;
            continue;
        }
        if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        } else if (c == '`') {
            // A nested template inside the interpolation: skip its whole body.
            const nend = templateBodyEnd(src, i + 1);
            i = if (nend < src.len) nend + 1 else nend;
            continue;
        } else if (c == '"' or c == '\'') {
            i += 1;
            while (i < src.len and src[i] != c) : (i += 1) {
                if (src[i] == '\\' and i + 1 < src.len) i += 1;
            }
            if (i < src.len) i += 1; // closing quote
            continue;
        }
        i += 1;
    }
    return i;
}

test "regex literal lexing and `/` disambiguation" {
    const t = std.testing;
    // After `=`, `/.../flags` is a regex.
    {
        var lx = Lexer{ .src = "const re = /ab+c/gi;" };
        _ = try lx.next(); // const
        _ = try lx.next(); // re
        _ = try lx.next(); // =
        const r = try lx.next();
        try t.expect(r == .regex);
        try t.expectEqualStrings("ab+c", r.regex.pattern);
        try t.expectEqualStrings("gi", r.regex.flags);
    }
    // After a value, `/` is division.
    {
        var lx = Lexer{ .src = "a / b" };
        _ = try lx.next(); // a
        const d = try lx.next();
        try t.expect(d == .op and d.op == '/');
    }
    // After `]`, `/` is division.
    {
        var lx = Lexer{ .src = "x[0] / 2" };
        _ = try lx.next();
        _ = try lx.next();
        _ = try lx.next();
        _ = try lx.next();
        const d = try lx.next();
        try t.expect(d == .op and d.op == '/');
    }
    // After a keyword, `/` is a regex.
    {
        var lx = Lexer{ .src = "return /x/;" };
        _ = try lx.next(); // return
        const r = try lx.next();
        try t.expect(r == .regex);
        try t.expectEqualStrings("x", r.regex.pattern);
        try t.expectEqualStrings("", r.regex.flags);
    }
    // `/` inside a `[...]` class does not terminate the body.
    {
        var lx = Lexer{ .src = "= /[a/b]+/" };
        _ = try lx.next(); // =
        const r = try lx.next();
        try t.expect(r == .regex);
        try t.expectEqualStrings("[a/b]+", r.regex.pattern);
    }
    // An escaped slash does not terminate the body.
    {
        var lx = Lexer{ .src = "= /a\\/b/" };
        _ = try lx.next(); // =
        const r = try lx.next();
        try t.expect(r == .regex);
        try t.expectEqualStrings("a\\/b", r.regex.pattern);
    }
}

test "`@` lexes as its own operator token (spec 455)" {
    const t = std.testing;
    var lx = Lexer{ .src = "@entity(\"agents\")\nclass Agent {}" };
    const at = try lx.next();
    try t.expect(at == .op and at.op == '@');
    try t.expectEqual(@as(u32, 1), lx.tok_line);
    try t.expectEqual(@as(u32, 1), lx.tok_col);
    const name = try lx.next();
    try t.expect(name == .ident);
    try t.expectEqualStrings("entity", name.ident);
    const open = try lx.next();
    try t.expect(open == .op and open.op == '(');
    const arg = try lx.next();
    try t.expect(arg == .str);
    try t.expectEqualStrings("agents", arg.str);
    _ = try lx.next(); // ')'
    const kw = try lx.next();
    try t.expect(kw == .ident);
    try t.expectEqualStrings("class", kw.ident);
    try t.expectEqual(@as(u32, 2), lx.tok_line);
}

test "a raw line break inside a string literal is flagged and counted (spec 502)" {
    const t = std.testing;
    // Double quotes, `\n`: the token keeps the raw bytes, is flagged, and the
    // next token's line reflects the break the literal spanned.
    {
        var lx = Lexer{ .src = "\"a\nb\" x" };
        const s = try lx.next();
        try t.expect(s == .str);
        try t.expectEqualStrings("a\nb", s.str);
        try t.expect(lx.str_raw_newline);
        try t.expectEqual(@as(u32, 1), lx.tok_line);
        try t.expectEqual(@as(u32, 1), lx.tok_col);
        try t.expectEqual(@as(usize, 0), lx.tok_start);
        const x = try lx.next();
        try t.expect(x == .ident);
        try t.expect(!lx.str_raw_newline);
        try t.expectEqual(@as(u32, 2), lx.tok_line);
        try t.expectEqual(@as(u32, 4), lx.tok_col);
    }
    // Single quotes, `\r\n`: flagged, and the bytes are not normalized.
    {
        var lx = Lexer{ .src = "'c\r\nd'" };
        const s = try lx.next();
        try t.expect(s == .str);
        try t.expectEqualStrings("c\r\nd", s.str);
        try t.expect(lx.str_raw_newline);
        try t.expectEqual(@as(u32, 2), lx.line);
    }
    // A lone `\r` is a line break to TypeScript too.
    {
        var lx = Lexer{ .src = "'c\rd'" };
        _ = try lx.next();
        try t.expect(lx.str_raw_newline);
    }
    // The escape sequence `\n` is the spelling to use: not flagged.
    {
        var lx = Lexer{ .src = "\"a\\nb\" y" };
        const s = try lx.next();
        try t.expectEqualStrings("a\\nb", s.str);
        try t.expect(!lx.str_raw_newline);
        _ = try lx.next();
        try t.expectEqual(@as(u32, 1), lx.tok_line);
    }
    // A template literal may span lines and is never flagged.
    {
        var lx = Lexer{ .src = "`a\nb` z" };
        const s = try lx.next();
        try t.expect(s == .template);
        try t.expect(!lx.str_raw_newline);
        _ = try lx.next();
        try t.expectEqual(@as(u32, 2), lx.tok_line);
    }
}

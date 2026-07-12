// Regex runtime for Lumen-compiled programs. A small backtracking engine over a
// practical subset of JS regex: literals, `.`, classes `[...]` with ranges and
// `\d \w \s` (and negations), quantifiers `* + ? {n,m}` (greedy), anchors `^ $`,
// groups `( )`, alternation `|`, escapes, and the `i` flag.
//
// This file is BOTH a standalone, `zig test`-able module AND embedded verbatim
// into generated programs (see lumen_compiler.zig). It therefore avoids clashing
// with the generated program's `std` by aliasing it as `__re_std`, and prefixes
// all public symbols with `__lumen_re_`.
const __re_std = @import("std");

// Everything lives inside one namespaced struct so that embedding this file into
// a generated program adds exactly one top-level name (`__lumen_regex`) and can
// never clash with a user's type/function names.
pub const __lumen_regex = struct {
    pub const Range = struct { lo: u8, hi: u8 };

    const digit_ranges = [_]Range{.{ .lo = '0', .hi = '9' }};
    const word_ranges = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' }, .{ .lo = '_', .hi = '_' } };
    const space_ranges = [_]Range{ .{ .lo = ' ', .hi = ' ' }, .{ .lo = 9, .hi = 13 } };

    pub const Class = struct { negated: bool, ranges: []const Range };

    pub const Node = union(enum) {
        empty,
        char: u8,
        any,
        class: Class,
        astart,
        aend,
        concat: []const *Node,
        alt: []const *Node,
        star: *Node,
        plus: *Node,
        quest: *Node,
    };

    const ParseError = error{ OutOfMemory, BadPattern };

    const Parser = struct {
        s: []const u8,
        i: usize = 0,
        a: __re_std.mem.Allocator,

        fn peek(self: *Parser) ?u8 {
            return if (self.i < self.s.len) self.s[self.i] else null;
        }

        fn mk(self: *Parser, n: Node) ParseError!*Node {
            const p = try self.a.create(Node);
            p.* = n;
            return p;
        }

        // alt := concat ('|' concat)*
        fn parseAlt(self: *Parser) ParseError!*Node {
            var alts: __re_std.ArrayListUnmanaged(*Node) = .empty;
            try alts.append(self.a, try self.parseConcat());
            while (self.peek() == '|') {
                self.i += 1;
                try alts.append(self.a, try self.parseConcat());
            }
            if (alts.items.len == 1) return alts.items[0];
            return self.mk(.{ .alt = alts.items });
        }

        // concat := quant*
        fn parseConcat(self: *Parser) ParseError!*Node {
            var items: __re_std.ArrayListUnmanaged(*Node) = .empty;
            while (self.peek()) |c| {
                if (c == '|' or c == ')') break;
                try items.append(self.a, try self.parseQuant());
            }
            if (items.items.len == 0) return self.mk(.empty);
            if (items.items.len == 1) return items.items[0];
            return self.mk(.{ .concat = items.items });
        }

        // quant := atom ('*' | '+' | '?' | '{n,m}')*
        fn parseQuant(self: *Parser) ParseError!*Node {
            var node = try self.parseAtom();
            while (self.peek()) |c| {
                switch (c) {
                    '*' => {
                        self.i += 1;
                        node = try self.mk(.{ .star = node });
                    },
                    '+' => {
                        self.i += 1;
                        node = try self.mk(.{ .plus = node });
                    },
                    '?' => {
                        self.i += 1;
                        node = try self.mk(.{ .quest = node });
                    },
                    '{' => {
                        const saved = self.i;
                        node = self.parseRepeat(node) catch |e| switch (e) {
                            error.BadPattern => blk: {
                                // Not a valid `{n,m}`; treat `{` as a literal.
                                self.i = saved;
                                break :blk node;
                            },
                            else => return e,
                        };
                        if (self.i == saved) break; // `{` was literal; stop quantifiers
                    },
                    else => break,
                }
            }
            return node;
        }

        // Desugars `x{n,m}` into a concat of copies plus optional/star tail.
        fn parseRepeat(self: *Parser, inner: *Node) ParseError!*Node {
            __re_std.debug.assert(self.s[self.i] == '{');
            var j = self.i + 1;
            const min = try __reReadInt(self.s, &j);
            var has_max = true;
            var max: u32 = min;
            if (j < self.s.len and self.s[j] == ',') {
                j += 1;
                if (j < self.s.len and self.s[j] == '}') {
                    has_max = false;
                } else {
                    max = try __reReadInt(self.s, &j);
                }
            }
            if (j >= self.s.len or self.s[j] != '}') return error.BadPattern;
            if (has_max and max < min) return error.BadPattern;
            self.i = j + 1;
            var items: __re_std.ArrayListUnmanaged(*Node) = .empty;
            var k: u32 = 0;
            while (k < min) : (k += 1) try items.append(self.a, inner);
            if (has_max) {
                var q = min;
                while (q < max) : (q += 1) try items.append(self.a, try self.mk(.{ .quest = inner }));
            } else {
                try items.append(self.a, try self.mk(.{ .star = inner }));
            }
            if (items.items.len == 0) return self.mk(.empty);
            if (items.items.len == 1) return items.items[0];
            return self.mk(.{ .concat = items.items });
        }

        fn parseAtom(self: *Parser) ParseError!*Node {
            const c = self.peek() orelse return self.mk(.empty);
            switch (c) {
                '(' => {
                    self.i += 1;
                    // Non-capturing group prefix `(?:` is accepted and ignored.
                    if (self.i + 1 < self.s.len and self.s[self.i] == '?' and self.s[self.i + 1] == ':') self.i += 2;
                    const inner = try self.parseAlt();
                    if (self.peek() != ')') return error.BadPattern;
                    self.i += 1;
                    return inner;
                },
                '[' => return self.parseClass(),
                '.' => {
                    self.i += 1;
                    return self.mk(.any);
                },
                '^' => {
                    self.i += 1;
                    return self.mk(.astart);
                },
                '$' => {
                    self.i += 1;
                    return self.mk(.aend);
                },
                '\\' => {
                    self.i += 1;
                    if (self.i >= self.s.len) return error.BadPattern;
                    const e = self.s[self.i];
                    self.i += 1;
                    return switch (e) {
                        'd' => self.mk(.{ .class = .{ .negated = false, .ranges = &digit_ranges } }),
                        'D' => self.mk(.{ .class = .{ .negated = true, .ranges = &digit_ranges } }),
                        'w' => self.mk(.{ .class = .{ .negated = false, .ranges = &word_ranges } }),
                        'W' => self.mk(.{ .class = .{ .negated = true, .ranges = &word_ranges } }),
                        's' => self.mk(.{ .class = .{ .negated = false, .ranges = &space_ranges } }),
                        'S' => self.mk(.{ .class = .{ .negated = true, .ranges = &space_ranges } }),
                        'n' => self.mk(.{ .char = '\n' }),
                        't' => self.mk(.{ .char = '\t' }),
                        'r' => self.mk(.{ .char = '\r' }),
                        else => self.mk(.{ .char = e }),
                    };
                },
                else => {
                    self.i += 1;
                    return self.mk(.{ .char = c });
                },
            }
        }

        fn parseClass(self: *Parser) ParseError!*Node {
            self.i += 1; // consume '['
            var negated = false;
            if (self.peek() == '^') {
                negated = true;
                self.i += 1;
            }
            var ranges: __re_std.ArrayListUnmanaged(Range) = .empty;
            while (self.peek()) |c| {
                if (c == ']') {
                    self.i += 1;
                    return self.mk(.{ .class = .{ .negated = negated, .ranges = ranges.items } });
                }
                var lo: u8 = c;
                if (c == '\\' and self.i + 1 < self.s.len) {
                    self.i += 1;
                    const e = self.s[self.i];
                    self.i += 1;
                    switch (e) {
                        'd' => {
                            try ranges.appendSlice(self.a, &digit_ranges);
                            continue;
                        },
                        'w' => {
                            try ranges.appendSlice(self.a, &word_ranges);
                            continue;
                        },
                        's' => {
                            try ranges.appendSlice(self.a, &space_ranges);
                            continue;
                        },
                        'n' => lo = '\n',
                        't' => lo = '\t',
                        'r' => lo = '\r',
                        else => lo = e,
                    }
                } else {
                    self.i += 1;
                }
                // Range `a-z` when a '-' followed by a non-']' char comes next.
                if (self.peek() == '-' and self.i + 1 < self.s.len and self.s[self.i + 1] != ']') {
                    self.i += 1; // consume '-'
                    var hi: u8 = self.s[self.i];
                    if (hi == '\\' and self.i + 1 < self.s.len) {
                        self.i += 1;
                        hi = self.s[self.i];
                    }
                    self.i += 1;
                    try ranges.append(self.a, .{ .lo = lo, .hi = hi });
                } else {
                    try ranges.append(self.a, .{ .lo = lo, .hi = lo });
                }
            }
            return error.BadPattern; // unterminated class
        }
    };

    fn __reReadInt(s: []const u8, j: *usize) ParseError!u32 {
        const start = j.*;
        var v: u32 = 0;
        while (j.* < s.len and s[j.*] >= '0' and s[j.*] <= '9') : (j.* += 1) {
            v = v * 10 + (s[j.*] - '0');
        }
        if (j.* == start) return error.BadPattern;
        return v;
    }

    // --- bytecode ---

    const Inst = union(enum) {
        char: u8,
        any,
        class: Class,
        match,
        jmp: usize,
        split: struct { x: usize, y: usize },
        astart,
        aend,
    };

    const Prog = __re_std.ArrayListUnmanaged(Inst);

    fn __reEmit(prog: *Prog, a: __re_std.mem.Allocator, inst: Inst) ParseError!usize {
        try prog.append(a, inst);
        return prog.items.len - 1;
    }

    fn __reCompile(node: *const Node, prog: *Prog, a: __re_std.mem.Allocator) ParseError!void {
        switch (node.*) {
            .empty => {},
            .char => |c| _ = try __reEmit(prog, a, .{ .char = c }),
            .any => _ = try __reEmit(prog, a, .any),
            .class => |cl| _ = try __reEmit(prog, a, .{ .class = cl }),
            .astart => _ = try __reEmit(prog, a, .astart),
            .aend => _ = try __reEmit(prog, a, .aend),
            .concat => |items| for (items) |it| try __reCompile(it, prog, a),
            .alt => |alts| {
                var jmps: __re_std.ArrayListUnmanaged(usize) = .empty;
                for (alts, 0..) |alt, idx| {
                    if (idx + 1 < alts.len) {
                        const sp = try __reEmit(prog, a, .{ .split = .{ .x = prog.items.len + 1, .y = 0 } });
                        try __reCompile(alt, prog, a);
                        try jmps.append(a, try __reEmit(prog, a, .{ .jmp = 0 }));
                        prog.items[sp].split.y = prog.items.len;
                    } else {
                        try __reCompile(alt, prog, a);
                    }
                }
                for (jmps.items) |jp| prog.items[jp].jmp = prog.items.len;
            },
            .star => |inner| {
                const l1 = try __reEmit(prog, a, .{ .split = .{ .x = 0, .y = 0 } });
                prog.items[l1].split.x = prog.items.len;
                try __reCompile(inner, prog, a);
                _ = try __reEmit(prog, a, .{ .jmp = l1 });
                prog.items[l1].split.y = prog.items.len;
            },
            .plus => |inner| {
                const l1 = prog.items.len;
                try __reCompile(inner, prog, a);
                _ = try __reEmit(prog, a, .{ .split = .{ .x = l1, .y = prog.items.len + 1 } });
            },
            .quest => |inner| {
                const sp = try __reEmit(prog, a, .{ .split = .{ .x = prog.items.len + 1, .y = 0 } });
                try __reCompile(inner, prog, a);
                prog.items[sp].split.y = prog.items.len;
            },
        }
    }

    fn __reLower(c: u8) u8 {
        return if (c >= 'A' and c <= 'Z') c + 32 else c;
    }

    fn __reChEq(a: u8, b: u8, ci: bool) bool {
        return if (ci) __reLower(a) == __reLower(b) else a == b;
    }

    fn __reInRanges(ranges: []const Range, ch: u8) bool {
        for (ranges) |r| if (ch >= r.lo and ch <= r.hi) return true;
        return false;
    }

    fn __reClassMatch(cl: Class, ch: u8, ci: bool) bool {
        var hit = __reInRanges(cl.ranges, ch);
        if (!hit and ci) {
            const swapped: u8 = if (ch >= 'a' and ch <= 'z') ch - 32 else if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            if (swapped != ch) hit = __reInRanges(cl.ranges, swapped);
        }
        return hit != cl.negated;
    }

    // Backtracking VM: does prog match `text` starting at `sp`?
    fn __reRun(prog: []const Inst, pc0: usize, text: []const u8, sp0: usize, ci: bool) bool {
        var pc = pc0;
        var sp = sp0;
        while (true) {
            switch (prog[pc]) {
                .match => return true,
                .char => |c| {
                    if (sp < text.len and __reChEq(text[sp], c, ci)) {
                        pc += 1;
                        sp += 1;
                    } else return false;
                },
                .any => {
                    if (sp < text.len and text[sp] != '\n') {
                        pc += 1;
                        sp += 1;
                    } else return false;
                },
                .class => |cl| {
                    if (sp < text.len and __reClassMatch(cl, text[sp], ci)) {
                        pc += 1;
                        sp += 1;
                    } else return false;
                },
                .astart => {
                    if (sp == 0) pc += 1 else return false;
                },
                .aend => {
                    if (sp == text.len) pc += 1 else return false;
                },
                .jmp => |x| pc = x,
                .split => |s| {
                    if (__reRun(prog, s.x, text, sp, ci)) return true;
                    pc = s.y;
                },
            }
        }
    }

    // Backtracking VM variant that reports the end offset of a match starting at
    // `sp0` (exclusive), or null. Mirrors `__reRun` but propagates the position
    // reached at the `.match` instruction so callers can compute a match span.
    fn __reRunEnd(prog: []const Inst, pc0: usize, text: []const u8, sp0: usize, ci: bool) ?usize {
        var pc = pc0;
        var sp = sp0;
        while (true) {
            switch (prog[pc]) {
                .match => return sp,
                .char => |c| {
                    if (sp < text.len and __reChEq(text[sp], c, ci)) {
                        pc += 1;
                        sp += 1;
                    } else return null;
                },
                .any => {
                    if (sp < text.len and text[sp] != '\n') {
                        pc += 1;
                        sp += 1;
                    } else return null;
                },
                .class => |cl| {
                    if (sp < text.len and __reClassMatch(cl, text[sp], ci)) {
                        pc += 1;
                        sp += 1;
                    } else return null;
                },
                .astart => {
                    if (sp == 0) pc += 1 else return null;
                },
                .aend => {
                    if (sp == text.len) pc += 1 else return null;
                },
                .jmp => |x| pc = x,
                .split => |s| {
                    if (__reRunEnd(prog, s.x, text, sp, ci)) |e| return e;
                    pc = s.y;
                },
            }
        }
    }

    /// A matched span `[start, end)` inside the input.
    pub const MatchSpan = struct { start: usize, end: usize };

    /// The leftmost match at or after `from`, or null. Scans start positions the
    /// same way `__reMatchOne` does, returning the first that matches.
    pub fn __reFind(c: Compiled, input: []const u8, from: usize) ?MatchSpan {
        var start: usize = from;
        while (start <= input.len) : (start += 1) {
            if (__reRunEnd(c.prog, 0, input, start, c.ci)) |e| return .{ .start = start, .end = e };
        }
        return null;
    }

    /// Parses `pattern` into its AST (used by the compiler at build time to decide
    /// whether a literal can be specialized into straight-line code). Null if the
    /// pattern is malformed.
    pub fn parse(a: __re_std.mem.Allocator, pattern: []const u8) ?*Node {
        var parser = Parser{ .s = pattern, .a = a };
        const ast = parser.parseAlt() catch return null;
        if (parser.i != pattern.len) return null;
        return ast;
    }

    /// A compiled regex: the bytecode program plus the case-insensitive flag. A
    /// regex literal is a constant, so this is built once and reused across matches.
    pub const Compiled = struct { prog: []const Inst, ci: bool, global: bool = false };

    /// Compiles `pattern`/`flags` into reusable bytecode (allocated in `a`). Returns
    /// null on a malformed pattern.
    pub fn __reCompilePattern(a: __re_std.mem.Allocator, pattern: []const u8, flags: []const u8) ?Compiled {
        var parser = Parser{ .s = pattern, .a = a };
        const ast = parser.parseAlt() catch return null;
        if (parser.i != pattern.len) return null; // trailing junk (e.g. stray ')')
        var prog: Prog = .empty;
        __reCompile(ast, &prog, a) catch return null;
        _ = __reEmit(&prog, a, .match) catch return null;
        var ci = false;
        var global = false;
        for (flags) |f| {
            if (f == 'i') ci = true;
            if (f == 'g') global = true;
        }
        return .{ .prog = prog.items, .ci = ci, .global = global };
    }

    /// Does the compiled regex match anywhere in `input` (JS `RegExp.test`)?
    pub fn __reMatchOne(c: Compiled, input: []const u8) bool {
        var start: usize = 0;
        while (start <= input.len) : (start += 1) {
            if (__reRun(c.prog, 0, input, start, c.ci)) return true;
        }
        return false;
    }

    /// Compile-and-match in one call (recompiles each time; for one-shot use).
    pub fn search(pattern: []const u8, flags: []const u8, input: []const u8) bool {
        var arena = __re_std.heap.ArenaAllocator.init(__re_std.heap.page_allocator);
        defer arena.deinit();
        const c = __reCompilePattern(arena.allocator(), pattern, flags) orelse return false;
        return __reMatchOne(c, input);
    }

    /// Replaces regex matches in `input` with `repl` (allocated in `a`). If the
    /// pattern has the `g` flag every match is replaced, otherwise just the
    /// first (JS `String.prototype.replace` with a RegExp and a plain string).
    /// A zero-width match advances one byte to avoid looping. On a bad pattern
    /// or allocation failure the input is returned unchanged.
    pub fn __reReplaceCompiled(a: __re_std.mem.Allocator, c: Compiled, input: []const u8, repl: []const u8) []const u8 {
        var out: __re_std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        var replaced = false;
        while (i <= input.len) {
            const m = __reFind(c, input, i) orelse break;
            out.appendSlice(a, input[i..m.start]) catch return input;
            out.appendSlice(a, repl) catch return input;
            replaced = true;
            if (m.end > i) {
                i = m.end;
            } else {
                // Zero-width match: keep the byte at the position and advance.
                if (m.start < input.len) out.append(a, input[m.start]) catch return input;
                i = m.start + 1;
            }
            if (!c.global) break;
        }
        if (!replaced) return input;
        if (i < input.len) out.appendSlice(a, input[i..]) catch return input;
        return out.items;
    }

    /// Compile-and-replace in one call (recompiles each time; for one-shot use).
    pub fn replaceRegex(a: __re_std.mem.Allocator, pattern: []const u8, flags: []const u8, input: []const u8, repl: []const u8) []const u8 {
        const c = __reCompilePattern(a, pattern, flags) orelse return input;
        return __reReplaceCompiled(a, c, input, repl);
    }

    /// The index of the first regex match in `input`, or -1 (JS
    /// `String.prototype.search`). On a bad pattern returns -1.
    pub fn searchRegex(a: __re_std.mem.Allocator, pattern: []const u8, flags: []const u8, input: []const u8) i64 {
        const c = __reCompilePattern(a, pattern, flags) orelse return -1;
        if (__reFind(c, input, 0)) |m| return @intCast(m.start);
        return -1;
    }

    /// Splits `input` at each regex match, returning the pieces (JS
    /// `String.prototype.split` with a RegExp separator). Zero-width matches are
    /// skipped to avoid looping, so an empty pattern yields the whole string as
    /// one piece. On a bad pattern the whole input is returned as one piece.
    /// `String.prototype.match` subset: a one-element slice holding the first
    /// match's full text, or null when the pattern doesn't match (or is
    /// malformed). Capture groups are not populated — the engine tracks match
    /// spans, not per-group spans.
    pub fn matchRegex(a: __re_std.mem.Allocator, pattern: []const u8, flags: []const u8, input: []const u8) ?[]const []const u8 {
        const c = __reCompilePattern(a, pattern, flags) orelse return null;
        const m = __reFind(c, input, 0) orelse return null;
        const out = a.alloc([]const u8, 1) catch return null;
        out[0] = input[m.start..m.end];
        return out;
    }

    pub fn splitRegex(a: __re_std.mem.Allocator, pattern: []const u8, flags: []const u8, input: []const u8) []const []const u8 {
        var parts: __re_std.ArrayListUnmanaged([]const u8) = .empty;
        const c = __reCompilePattern(a, pattern, flags) orelse {
            parts.append(a, input) catch return &.{};
            return parts.items;
        };
        var last: usize = 0;
        var i: usize = 0;
        while (i <= input.len) {
            const m = __reFind(c, input, i) orelse break;
            if (m.end == m.start) {
                // Zero-width match: cannot delimit a piece; step past it.
                i = m.start + 1;
                continue;
            }
            parts.append(a, input[last..m.start]) catch return parts.items;
            last = m.end;
            i = m.end;
        }
        parts.append(a, input[last..]) catch return parts.items;
        return parts.items;
    }
};

test "regex engine: literals, anchors, quantifiers, classes, alternation, flags" {
    const t = __re_std.testing;
    const S = __lumen_regex.search;
    // literals + unanchored search
    try t.expect(S("abc", "", "xabcy"));
    try t.expect(!S("abc", "", "abx"));
    // quantifiers
    try t.expect(S("ab+c", "", "xabbbc"));
    try t.expect(!S("ab+c", "", "ac"));
    try t.expect(S("ab*c", "", "ac"));
    try t.expect(S("colou?r", "", "color"));
    try t.expect(S("colou?r", "", "colour"));
    // anchors
    try t.expect(S("^\\d+$", "", "12345"));
    try t.expect(!S("^\\d+$", "", "12a45"));
    try t.expect(!S("^abc$", "", "xabc"));
    // classes + ranges + shorthands
    try t.expect(S("[a-z]+", "", "Hello"));
    try t.expect(!S("^[a-z]+$", "", "Hello"));
    try t.expect(S("[^0-9]", "", "a"));
    try t.expect(S("\\w+", "", "foo_bar9"));
    try t.expect(S("\\s", "", "a b"));
    try t.expect(!S("\\s", "", "ab"));
    // {n,m}
    try t.expect(S("^a{2,4}$", "", "aaa"));
    try t.expect(!S("^a{2,4}$", "", "a"));
    try t.expect(!S("^a{2,4}$", "", "aaaaa"));
    try t.expect(S("^\\d{3}$", "", "123"));
    // alternation + groups
    try t.expect(S("^(cat|dog|bird)$", "", "dog"));
    try t.expect(!S("^(cat|dog)$", "", "fish"));
    try t.expect(S("^(ab)+$", "", "ababab"));
    // i flag
    try t.expect(S("hello", "i", "HELLO"));
    try t.expect(S("[a-z]+", "i", "ABC"));
    try t.expect(!S("hello", "", "HELLO"));
    // escaped metachars
    try t.expect(S("a\\.b", "", "a.b"));
    try t.expect(!S("a\\.b", "", "axb"));
    // a semver-ish pattern
    try t.expect(S("^\\d+\\.\\d+\\.\\d+$", "", "1.2.30"));
    try t.expect(!S("^\\d+\\.\\d+\\.\\d+$", "", "1.2"));
}

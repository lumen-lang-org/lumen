const std = @import("std");

const Manifest = struct {
    feature: []const u8,
    cases: []Case,
};

const Case = struct {
    id: []const u8,
    source: []const u8,
    phase: []const u8,
    expect: Expect,
};

const Expect = struct {
    stdout: ?[]const u8 = null,
    diagnostic: ?[]const u8 = null,
    noDiagnostic: ?[]const u8 = null, // compile-warn: text that must NOT appear on the compile's stderr
    inferredTypes: ?std.json.Value = null,
    acceptedTypes: ?[]const []const u8 = null,
    // test-run / node-test-run: substrings that must all appear in the test
    // run's stderr (specs 242, 243 -- the `ok`/`FAIL`/tally rendering). When
    // set, the case's outcome is judged by these substrings rather than by
    // plain exit success: any substring containing "FAIL " means the fixture
    // has a deliberately failing test, so the run is expected to exit
    // nonzero; otherwise it is expected to exit zero, same as a plain
    // `test-run`/`node-test-run` case.
    testOutput: ?[]const []const u8 = null,
};

const Stats = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};

fn usage() void {
    std.debug.print("usage: lumen-conformance <manifest.json> <lumen-binary>\n", .{});
}

fn manifestDir(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn resolveSource(arena: std.mem.Allocator, manifest_path: []const u8, source: []const u8) ![]const u8 {
    return std.fs.path.resolve(arena, &.{ manifestDir(manifest_path), source });
}

fn trimTrailingNewlines(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\r\n");
}

fn exeNameForSource(arena: std.mem.Allocator, source_path: []const u8) ![]const u8 {
    const stem = std.fs.path.stem(source_path);
    if (@import("builtin").os.tag == .windows) {
        return std.fmt.allocPrint(arena, "{s}.exe", .{stem});
    }
    return arena.dupe(u8, stem);
}

fn removeGenerated(io: std.Io, source_path: []const u8, exe_name: []const u8) void {
    const stem = std.fs.path.stem(source_path);
    var zig_name_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&zig_name_buf, "{s}.zig", .{stem})) |zig_name| {
        std.Io.Dir.cwd().deleteFile(io, zig_name) catch {};
    } else |_| {}
    std.Io.Dir.cwd().deleteFile(io, exe_name) catch {};
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn runProcess(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .reserve_amount = 4096,
    });
}

fn checkCompileRun(arena: std.mem.Allocator, io: std.Io, case: Case, source_path: []const u8, lumen_bin: []const u8) !bool {
    const compile = try runProcess(arena, io, &.{ lumen_bin, "compile", source_path });
    if (!termSucceeded(compile.term)) {
        std.debug.print("FAIL {s}: compile failed\n{s}\n", .{ case.id, compile.stderr });
        return false;
    }

    const exe_name = try exeNameForSource(arena, source_path);
    defer removeGenerated(io, source_path, exe_name);

    const exe_path = try std.fmt.allocPrint(arena, "./{s}", .{exe_name});
    const run = try runProcess(arena, io, &.{exe_path});
    if (!termSucceeded(run.term)) {
        std.debug.print("FAIL {s}: executable failed\n{s}\n", .{ case.id, run.stderr });
        return false;
    }

    const expected = case.expect.stdout orelse "";
    // Concatenate stdout+stderr rather than picking one statically: spec 048
    // fixed a real bug where console.log/error both landed on stderr
    // (std.debug.print, unconditionally); some older manifest cases (e.g.
    // console-stdlib.ts's console.error case) were written against that
    // buggy routing. Concatenating keeps every existing case's expectation
    // correct regardless of which real stream a case's output lands on.
    const combined = std.fmt.allocPrint(arena, "{s}{s}", .{ run.stdout, run.stderr }) catch return false;
    const actual = trimTrailingNewlines(combined);
    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("FAIL {s}: stdout mismatch\nexpected:\n{s}\nactual:\n{s}\n", .{ case.id, expected, actual });
        return false;
    }
    return true;
}

// The node target (spec 504): `lumen compile --target node` writes
// `<stem>.node/` into the working directory; `node <stem>.node/<stem>.mjs`
// must print what the case expects -- the same bytes the native binary
// prints, since a `node-run` case is written against the native expectation.
// stdout and stderr are concatenated as for `compile-run`.
fn checkNodeRun(arena: std.mem.Allocator, io: std.Io, case: Case, source_path: []const u8, lumen_bin: []const u8) !bool {
    const compile = try runProcess(arena, io, &.{ lumen_bin, "compile", "--target", "node", source_path });
    const out_dir = try std.fmt.allocPrint(arena, "{s}.node", .{std.fs.path.stem(source_path)});
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    if (!termSucceeded(compile.term)) {
        std.debug.print("FAIL {s}: node compile failed\n{s}\n", .{ case.id, compile.stderr });
        return false;
    }

    const entry = try std.fmt.allocPrint(arena, "{s}/{s}.mjs", .{ out_dir, std.fs.path.stem(source_path) });
    const run = try runProcess(arena, io, &.{ "node", entry });
    if (!termSucceeded(run.term)) {
        std.debug.print("FAIL {s}: node run failed\n{s}\n", .{ case.id, run.stderr });
        return false;
    }

    const expected = case.expect.stdout orelse "";
    const combined = std.fmt.allocPrint(arena, "{s}{s}", .{ run.stdout, run.stderr }) catch return false;
    const actual = trimTrailingNewlines(combined);
    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("FAIL {s}: node stdout mismatch\nexpected:\n{s}\nactual:\n{s}\n", .{ case.id, expected, actual });
        return false;
    }
    return true;
}

// A program the node target must refuse at compile time (spec 504 FR-005):
// `lumen compile --target node` fails and its stderr names the diagnostic.
fn checkNodeDiagnostics(arena: std.mem.Allocator, io: std.Io, case: Case, source_path: []const u8, lumen_bin: []const u8) !bool {
    const compile = try runProcess(arena, io, &.{ lumen_bin, "compile", "--target", "node", source_path });
    const out_dir = try std.fmt.allocPrint(arena, "{s}.node", .{std.fs.path.stem(source_path)});
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    if (termSucceeded(compile.term)) {
        std.debug.print("FAIL {s}: expected a node-target diagnostic but the compile succeeded\n", .{case.id});
        return false;
    }
    const expected = case.expect.diagnostic orelse {
        std.debug.print("FAIL {s}: node-diagnostics case missing expected diagnostic\n", .{case.id});
        return false;
    };
    if (std.mem.indexOf(u8, compile.stderr, expected) == null) {
        std.debug.print("FAIL {s}: diagnostic mismatch, expected {s}\nactual:\n{s}\n", .{ case.id, expected, compile.stderr });
        return false;
    }
    return true;
}

fn checkDiagnostics(arena: std.mem.Allocator, io: std.Io, case: Case, source_path: []const u8, lumen_bin: []const u8) !bool {
    const compile = try runProcess(arena, io, &.{ lumen_bin, "compile", source_path });
    const exe_name = try exeNameForSource(arena, source_path);
    defer removeGenerated(io, source_path, exe_name);

    if (termSucceeded(compile.term)) {
        std.debug.print("FAIL {s}: expected diagnostic but compile succeeded\n", .{case.id});
        return false;
    }
    const expected = case.expect.diagnostic orelse {
        std.debug.print("FAIL {s}: diagnostics case missing expected diagnostic\n", .{case.id});
        return false;
    };
    if (std.mem.indexOf(u8, compile.stderr, expected) == null) {
        std.debug.print("FAIL {s}: diagnostic mismatch, expected {s}\nactual:\n{s}\n", .{ case.id, expected, compile.stderr });
        return false;
    }
    return true;
}

// A warning (spec 502): the compile MUST succeed and its stderr MUST contain
// `expect.diagnostic`. The `diagnostics` phase requires a failed compile, so a
// warning had no phase before this one. `expect.noDiagnostic` is the converse,
// for pinning that a construct stays silent; a case may give either or both.
fn checkCompileWarn(arena: std.mem.Allocator, io: std.Io, case: Case, source_path: []const u8, lumen_bin: []const u8) !bool {
    const compile = try runProcess(arena, io, &.{ lumen_bin, "compile", source_path });
    const exe_name = try exeNameForSource(arena, source_path);
    defer removeGenerated(io, source_path, exe_name);

    if (!termSucceeded(compile.term)) {
        std.debug.print("FAIL {s}: compile failed\n{s}\n", .{ case.id, compile.stderr });
        return false;
    }
    if (case.expect.diagnostic == null and case.expect.noDiagnostic == null) {
        std.debug.print("FAIL {s}: compile-warn case missing expected diagnostic or noDiagnostic\n", .{case.id});
        return false;
    }
    if (case.expect.diagnostic) |expected| {
        if (std.mem.indexOf(u8, compile.stderr, expected) == null) {
            std.debug.print("FAIL {s}: warning mismatch, expected {s}\nactual:\n{s}\n", .{ case.id, expected, compile.stderr });
            return false;
        }
    }
    if (case.expect.noDiagnostic) |unexpected| {
        if (std.mem.indexOf(u8, compile.stderr, unexpected) != null) {
            std.debug.print("FAIL {s}: unexpected warning {s}\nactual:\n{s}\n", .{ case.id, unexpected, compile.stderr });
            return false;
        }
    }
    return true;
}

fn checkStatic(arena: std.mem.Allocator, io: std.Io, case: Case, source_path: []const u8, lumen_bin: []const u8) !bool {
    const compile = try runProcess(arena, io, &.{ lumen_bin, "compile", source_path });
    const exe_name = try exeNameForSource(arena, source_path);
    defer removeGenerated(io, source_path, exe_name);

    if (!termSucceeded(compile.term)) {
        std.debug.print("FAIL {s}: static compile failed\n{s}\n", .{ case.id, compile.stderr });
        return false;
    }
    return true;
}

// Shared by `checkTestRun`/`checkNodeTestRun` when a case sets
// `expect.testOutput` (specs 242, 243): checks that every listed substring
// appears in the run's stderr, that the exit status agrees with whether any
// of them names a failure, and (when `expect.stdout` is also set) that it
// appears as a substring of the program's own stdout -- console.log inside a
// test passes through unrouted through the test reporter.
fn checkTestOutputExpectation(case: Case, run: std.process.RunResult, expected: []const []const u8) bool {
    var want_fail = false;
    for (expected) |s| {
        if (std.mem.indexOf(u8, s, "FAIL ") != null) want_fail = true;
    }
    const succeeded = termSucceeded(run.term);
    if (want_fail == succeeded) {
        std.debug.print("FAIL {s}: expected the run to exit {s}\n{s}\n", .{ case.id, if (want_fail) "nonzero (a test fails)" else "zero (all tests pass)", run.stderr });
        return false;
    }
    for (expected) |s| {
        if (std.mem.indexOf(u8, run.stderr, s) == null) {
            std.debug.print("FAIL {s}: expected output to contain {s}\nactual:\n{s}\n", .{ case.id, s, run.stderr });
            return false;
        }
    }
    if (case.expect.stdout) |want_stdout| {
        if (std.mem.indexOf(u8, run.stdout, want_stdout) == null) {
            std.debug.print("FAIL {s}: expected stdout to contain {s}\nactual:\n{s}\n", .{ case.id, want_stdout, run.stdout });
            return false;
        }
    }
    return true;
}

fn checkTestRun(arena: std.mem.Allocator, io: std.Io, case: Case, source_path: []const u8, lumen_bin: []const u8) !bool {
    const run = try runProcess(arena, io, &.{ lumen_bin, "test", source_path });
    const exe_name = try exeNameForSource(arena, source_path);
    defer removeGenerated(io, source_path, exe_name);
    if (case.expect.testOutput) |expected| {
        return checkTestOutputExpectation(case, run, expected);
    }
    if (!termSucceeded(run.term)) {
        std.debug.print("FAIL {s}: tests failed\n{s}\n", .{ case.id, run.stderr });
        return false;
    }
    return true;
}

// The node target's test runner (spec 506): `lumen test --target node` writes
// `<stem>.node/` and runs the entry under `node --test`; the case passes iff
// every test in the file did, the same rule as `test-run`.
fn checkNodeTestRun(arena: std.mem.Allocator, io: std.Io, case: Case, source_path: []const u8, lumen_bin: []const u8) !bool {
    const out_dir = try std.fmt.allocPrint(arena, "{s}.node", .{std.fs.path.stem(source_path)});
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    const run = try runProcess(arena, io, &.{ lumen_bin, "test", "--target", "node", source_path });
    if (case.expect.testOutput) |expected| {
        return checkTestOutputExpectation(case, run, expected);
    }
    if (!termSucceeded(run.term)) {
        std.debug.print("FAIL {s}: node tests failed\n{s}\n", .{ case.id, run.stderr });
        return false;
    }
    return true;
}

// A program that must be rejected specifically when compiled for `lumen test`
// (some diagnostics fire only in test mode — e.g. a module-level binding whose
// initializer can't be replayed before tests run, spec 449). Mirrors
// `checkDiagnostics` but drives `lumen test` instead of `lumen compile`.
fn checkTestDiagnostics(arena: std.mem.Allocator, io: std.Io, case: Case, source_path: []const u8, lumen_bin: []const u8) !bool {
    const run = try runProcess(arena, io, &.{ lumen_bin, "test", source_path });
    const exe_name = try exeNameForSource(arena, source_path);
    defer removeGenerated(io, source_path, exe_name);
    if (termSucceeded(run.term)) {
        std.debug.print("FAIL {s}: expected a test-mode diagnostic but the tests ran\n", .{case.id});
        return false;
    }
    const expected = case.expect.diagnostic orelse {
        std.debug.print("FAIL {s}: test-diagnostics case missing expected diagnostic\n", .{case.id});
        return false;
    };
    if (std.mem.indexOf(u8, run.stderr, expected) == null) {
        std.debug.print("FAIL {s}: diagnostic mismatch, expected {s}\nactual:\n{s}\n", .{ case.id, expected, run.stderr });
        return false;
    }
    return true;
}

/// The node target's corpus (spec 504 SC-001): the programs, from every spec,
/// that must print the same bytes under `node` as natively -- one path per
/// line relative to `specs/`, `#` comments. A `compile-run` case whose source
/// is listed is also run as `node-run` against the same expectation, so the
/// whole-corpus `zig build conformance` covers the node target without a
/// second copy of every case. Missing file: no node runs.
fn loadNodeCorpus(arena: std.mem.Allocator, io: std.Io, manifest_path: []const u8) []const []const u8 {
    const path = std.fs.path.resolve(arena, &.{ manifestDir(manifest_path), "..", "..", "504-node-target-emitter", "conformance", "corpus.txt" }) catch return &.{};
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch return &.{};
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        list.append(arena, line) catch return &.{};
    }
    return list.items;
}

fn inNodeCorpus(corpus: []const []const u8, source_path: []const u8) bool {
    for (corpus) |entry| {
        if (source_path.len > entry.len and std.mem.endsWith(u8, source_path, entry) and source_path[source_path.len - entry.len - 1] == '/') return true;
    }
    return false;
}

fn runCase(arena: std.mem.Allocator, io: std.Io, manifest_path: []const u8, case: Case, lumen_bin: []const u8) !?bool {
    const source_path = try resolveSource(arena, manifest_path, case.source);
    if (std.mem.eql(u8, case.phase, "compile-run")) {
        return try checkCompileRun(arena, io, case, source_path, lumen_bin);
    }
    if (std.mem.eql(u8, case.phase, "test-run")) {
        return try checkTestRun(arena, io, case, source_path, lumen_bin);
    }
    if (std.mem.eql(u8, case.phase, "diagnostics")) {
        return try checkDiagnostics(arena, io, case, source_path, lumen_bin);
    }
    if (std.mem.eql(u8, case.phase, "compile-warn")) {
        return try checkCompileWarn(arena, io, case, source_path, lumen_bin);
    }
    if (std.mem.eql(u8, case.phase, "test-diagnostics")) {
        return try checkTestDiagnostics(arena, io, case, source_path, lumen_bin);
    }
    if (std.mem.eql(u8, case.phase, "static")) {
        return try checkStatic(arena, io, case, source_path, lumen_bin);
    }
    if (std.mem.eql(u8, case.phase, "node-run")) {
        return try checkNodeRun(arena, io, case, source_path, lumen_bin);
    }
    if (std.mem.eql(u8, case.phase, "node-test-run")) {
        return try checkNodeTestRun(arena, io, case, source_path, lumen_bin);
    }
    if (std.mem.eql(u8, case.phase, "node-diagnostics")) {
        return try checkNodeDiagnostics(arena, io, case, source_path, lumen_bin);
    }
    std.debug.print("SKIP {s}: unsupported phase {s}\n", .{ case.id, case.phase });
    return null;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        usage();
        std.process.exit(2);
    }

    const manifest_path = args[1];
    const lumen_bin = args[2];
    const manifest_json = try std.Io.Dir.cwd().readFileAlloc(init.io, manifest_path, arena, .limited(4 * 1024 * 1024));
    const manifest = try std.json.parseFromSliceLeaky(Manifest, arena, manifest_json, .{ .ignore_unknown_fields = true });

    var stats: Stats = .{};
    const node_corpus = loadNodeCorpus(arena, init.io, manifest_path);
    std.debug.print("conformance: {s} ({d} cases)\n", .{ manifest.feature, manifest.cases.len });
    for (manifest.cases) |case| {
        const result = runCase(arena, init.io, manifest_path, case, lumen_bin) catch |err| {
            stats.failed += 1;
            std.debug.print("FAIL {s}: {s}\n", .{ case.id, @errorName(err) });
            continue;
        };
        if (result) |passed| {
            if (passed) {
                stats.passed += 1;
                std.debug.print("PASS {s}\n", .{case.id});
            } else {
                stats.failed += 1;
            }
        } else {
            stats.skipped += 1;
        }
        // The same program under the node target (spec 504), when listed.
        if (!std.mem.eql(u8, case.phase, "compile-run")) continue;
        const source_path = resolveSource(arena, manifest_path, case.source) catch continue;
        if (!inNodeCorpus(node_corpus, source_path)) continue;
        var node_case = case;
        node_case.id = try std.fmt.allocPrint(arena, "{s}.node", .{case.id});
        const node_result = checkNodeRun(arena, init.io, node_case, source_path, lumen_bin) catch |err| {
            stats.failed += 1;
            std.debug.print("FAIL {s}: {s}\n", .{ node_case.id, @errorName(err) });
            continue;
        };
        if (node_result) {
            stats.passed += 1;
            std.debug.print("PASS {s}\n", .{node_case.id});
        } else {
            stats.failed += 1;
        }
    }

    std.debug.print("conformance result: {d} passed, {d} failed, {d} skipped\n", .{ stats.passed, stats.failed, stats.skipped });
    if (stats.failed != 0) std.process.exit(1);
}

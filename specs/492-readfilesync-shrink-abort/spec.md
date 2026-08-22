# 492 — fs.readFileSync no longer aborts on a shrinking file (fixes #25)

## Problem

`__readFileSync` in `src/lumen_runtime_fs.zig` (emitted by `emitFsRuntime`)
read the whole file through `std.Io.Dir.readFileAlloc`:

```zig
fn __readFileSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) error{LumenThrow}![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024)) catch |e| { ... };
}
```

`readFileAlloc` opens the file, builds a `File.Reader` around it, and calls
`allocRemainingAlignedSentinel`, which (for a real file) takes the
`sendFile`/positional streaming path in `Io/File/Reader.zig` and `Io/Writer.zig`.
That path calls `getSize()` — an `fstat` cached on first use — and, on each
subsequent read, computes `size - pos` to bound how much more to transfer.
If the file shrinks between that stat and a later read of it, `pos` can end
up larger than the now-stale `size`, and that subtraction wraps. Zig's
runtime safety check turns the wraparound into a trap, not a catchable
error: no Lumen exception, no `error.LumenThrow`, the process just aborts.
A `try`/`catch` around `fs.readFileSync` in Lumen source cannot protect
against this, because the panic happens underneath the Zig call, not as a
Lumen-level error return. Filed as
[lumen-lang-org/lumen#25](https://github.com/lumen-lang-org/lumen/issues/25).

This is a real hazard independent of any other bug: any code shrinking a
file a reader is concurrently reading triggers it — `fs.truncateSync`,
`fs.ftruncateSync`, a `fs.writeFileSync` with shorter content, another
process entirely. It is also what #26 made common in practice: the old
read-concat-rewrite `appendFileSync` truncated the target file to zero
length on every single call, so any reader racing an appender hit this
constantly (documented in #491's write-up as the most frequent trigger, but
not the only one).

**Reproduced independent of Lumen entirely**, to nail down the exact
mechanism before touching this file: a standalone Zig program using
`std.Io.Dir.readFileAlloc` in a loop against a file a second thread
truncates and regrows on a tight loop panics within the first handful of
iterations, every time:

```
thread 594319 panic: integer overflow
/usr/lib/zig/std/Io/Writer.zig:2730:67: 0x1205e4b in sendFile (std.zig)
    const additional = if (file_reader.getSize()) |size| size - pos else |_| std.atomic.cache_line;
                                                              ^
```

## Change

`__readFileSync` no longer calls `readFileAlloc` (or anything else that
consults a cached file size) at all. It opens the file and reads it with a
manual `readStreaming` loop into a growing buffer — the same primitive
`__readSync` (fs.readSync) already uses elsewhere in this file — accumulating
until end-of-file or the same 16 MiB limit the old code enforced:

```zig
fn __readFileSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) error{LumenThrow}![]const u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |e| { ... };
    defer file.close(io);
    const read_limit: usize = 16 * 1024 * 1024;
    var list: std.ArrayListUnmanaged(u8) = .empty;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{chunk[0..]}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => { ... },
        };
        if (n == 0) break;
        if (list.items.len + n > read_limit) { ... }
        list.appendSlice(alloc, chunk[0..n]) catch { ... };
    }
    return list.toOwnedSlice(alloc) catch { ... };
}
```

`readStreaming` never looks at the file's size — it just reports how many
bytes a single `readv()` syscall actually returned — so there is no
`size - pos` anywhere in this path to wrap. A file that shrinks mid-read
now yields whatever bytes are actually still there (a short read) rather
than a trap. (`readStreaming` signals genuine end-of-file as
`error.EndOfStream`, not a 0-length return the way the positional read APIs
do — confirmed by reading `fileReadStreamingPosix`, which returns
`error.EndOfStream` on `rc == 0` — so that specific error is treated as
normal loop termination, not a failure.)

**This is a workaround, not a fix to the actual bug.** The `size - pos`
wraparound lives in the vendored Zig 0.16.0 standard library
(`Io/Writer.zig:2730`, reached via `Io/File/Reader.zig`'s `sendFile` path),
not in this repository. Lumen's `readFileAlloc`-based fs calls that are not
touched by this change (there are none currently reachable from user code
other than `readFileSync`) would still be exposed to the same underlying
issue if a future change routed something else through that path. Worth
reporting upstream to the Zig project; not filed as part of this change.

## Verified

- `zig build` and `zig build test` green.
- Standalone Zig repro (independent of Lumen, see above): 300000 iterations
  of the same shrink/grow race against the old `readFileAlloc`-based
  approach panics reliably in the first few iterations; the same harness
  rewritten against the manual `readStreaming` loop runs all 300000
  iterations with zero crashes.
- Lumen-level repro: one process truncating then rewriting a 512 KiB file in
  a tight loop, a sibling process calling `fs.readFileSync` in a
  200000-iteration loop wrapped in try/catch.
  - Baseline: `shrink_reader.ts:11:11: runtime error: integer overflow` at
    the `fs.readFileSync` call, process aborts before completing its read
    loop (`reader_done` is never printed); the try/catch does not intercept
    it.
  - Fixed: all 200000 iterations complete, 0 errors, no abort.
- `zig build conformance`, diffed against a fresh baseline built from the
  same base commit: identical sorted `FAIL` lists, no new failures.
- Downstream: `joule-sh/code` (copied, not modified) built against the
  patched compiler; its own test suite passes.

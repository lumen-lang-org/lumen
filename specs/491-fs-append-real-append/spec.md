# 491 — fs.appendFileSync uses real O_APPEND (fixes #26)

## Problem

`__appendFileSync` in `src/lumen_runtime_fs.zig` (emitted by
`emitFsRuntime`) had no direct append primitive available through
`std.Io.Dir`, so every call read the whole existing file, concatenated the
new data onto it in memory, and rewrote the file from scratch:

```zig
fn __appendFileSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8, data: []const u8) error{LumenThrow}!void {
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch "";
    const combined = std.mem.concat(alloc, u8, &.{ existing, data }) catch { ... };
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = combined }) catch |e| { ... };
}
```

`writeFile` creates-or-truncates: every append opened the target with
`O_WRONLY|O_CREAT|O_TRUNC`, confirmed by syscall trace
(`strace -f -e trace=openat,write,lseek`), preceded by an `O_RDONLY` open to
read the existing content back in. Filed as
[lumen-lang-org/lumen#26](https://github.com/lumen-lang-org/lumen/issues/26).

Two consequences, both load-bearing for `joule-sh/code`'s mailbox transcript,
which appends one entry per message:

- The file is genuinely zero-length for the span between the truncate and
  the rewrite completing. A concurrent reader — a second process, a tailing
  process, anything watching the file grow — can observe it empty, not just
  stale.
- Cost is quadratic: N appends rewrite the whole transcript N times.
  `joule-sh/code`'s own PR #119 worked around this from the caller's side
  (rewriting the mailbox to append instead of rewrite), taking 2000 appends
  from 91s to 15ms without ever touching this file — evidence the bug is
  real and costly, not just a correctness nit.

## Change

`__appendFileSync` no longer reads the file at all. `std.Io.Dir`'s
`CreateFileOptions`/`OpenFileOptions` (`Dir.zig`) have no append flag to ask
for — confirmed by reading `dirCreateFilePosix` in the `Threaded` `Io`
backend, which only ever sets `ACCMODE`/`CREAT`/`TRUNC`/`EXCL`/lock flags on
the `openat()` call, so there is no way to reach real `O_APPEND` through that
surface regardless of which options are passed. Real `O_APPEND` is reachable
one layer down: `std.Io.File` is just `{ handle, flags }`, freely
constructible, so the fix opens the file with `std.posix.openat` directly,
setting `O_APPEND` itself, and wraps the resulting fd as a `std.Io.File` so
the actual write still goes through the normal `Io` path
(`writeStreamingAll` -> `writev()`):

```zig
fn __appendFileSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8, data: []const u8) error{LumenThrow}!void {
    var flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    const mode = std.Io.File.Permissions.default_file.toMode();
    const fd = std.posix.openat(std.Io.Dir.cwd().handle, path, flags, mode) catch |e| { ... };
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    file.writeStreamingAll(io, data) catch |e| { ... };
}
```

**Atomicity guarantee.** This is real kernel `O_APPEND`, not the
lseek-then-write shortcut `fs.open`'s `"a"` mode already uses elsewhere in
this same file (`__openSync`): that path opens once and seeks to end-of-file
once, so it only holds up under a single writer for the file's lifetime (a
caveat `joule-sh/code`'s own PR #119 had to discover and document, since it
adopted that mode for its mailbox). With `O_APPEND` set at open time, the
kernel atomically repositions to end-of-file on every `write`/`writev`
syscall, so two writers appending to the same path concurrently each get
their bytes placed atomically at whatever the end offset is at the moment of
their write. They cannot interleave mid-write and cannot clobber each
other — a guarantee the seek-then-write approach cannot make, since a second
writer's `lseek(SEEK_END)` can land between another writer's seek and its
write.

`fs.appendFileSync` remains a single call per invocation (no internal
retry/rotation), so this is exactly the guarantee POSIX gives `O_APPEND`
writes up to `PIPE_BUF`-scale atomicity for a single `write()`; Lumen's
`writeStreamingAll` issues the data as one `writev()` call per
`appendFileSync` invocation.

## Verified

- `zig build` and `zig build test` green.
- **Syscall trace** (the same method that found the bug): baseline shows,
  for every `appendFileSync` call, an `O_RDONLY` open followed by
  `O_WRONLY|O_CREAT|O_TRUNC`; the fix shows `O_WRONLY|O_CREAT|O_APPEND`, no
  `O_TRUNC`, no preceding read.
- Minimal repro: write `"AAAA"`, append `"BBBB"` then `"CCCC"`, read back —
  `"AAAABBBBCCCC"` on both trees (this bug was never about the final byte
  content for a single sequential writer; it's about the window in between
  and about cost).
- Concurrent writer/reader repro: one process appending 300 single-byte
  writes in a loop, a sibling process reading the same file in a 20000-
  iteration loop, checking that the observed length never regresses and
  every byte read back is the one character being written.
  - Baseline: 5197/20000 reads observed the file shorter than a length
    already seen (truncation windows caught live), and the writer had only
    completed 51/300 appends by the time the reader finished — the
    quadratic cost visibly slowing the writer down under the same load.
  - Fixed: 0/20000 regressions, writer completed all 300 appends.
- `zig build conformance`, diffed against a fresh baseline built from the
  same base commit: identical sorted `FAIL` lists, no new failures.
- Downstream: `joule-sh/code` (copied, not modified) built against the
  patched compiler; its own test suite passes.

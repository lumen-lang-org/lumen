# Tasks: fs API expansion

## Phase 1

- [x] T1 `fs.rmdirSync(path)` — checker + codegen + `__rmdirSync` helper (`Dir.deleteDir`).
- [x] T2 `fs.rmSync(path, recursive?)` — `Dir.deleteFile`/`deleteTree`, default `recursive=false`.
- [x] T3 `fs.truncateSync(path, len)` — `Dir.openFile` (write) + `File.setLength`.
- [x] T4 `fs.linkSync(existingPath, newPath)` — `Dir.hardLink`.
- [x] T5 `fs.symlinkSync(target, path)` — `Dir.symLink`.
- [x] T6 `fs.readlinkSync(path)` — `Dir.readLink` into a buffer, dupe into the arena.
- [x] T7 `fs.chmodSync(path, mode)` — `Dir.openFile` + `File.setPermissions(.fromMode(mode))`.
- [x] T8 `fs.accessSync(path, mode?)` — `Dir.access` with `AccessOptions` from the POSIX bitmask.
- [x] T9 Verify: one program exercises all 8 together; `zig build test` + regex
  differential unaffected.
- [x] T10 Update `website/stdlib.html`: move the 8 from Planned to Available now.

## Phase 3 (re-scoped: not actually blocked)

- [x] T11 `fs.lstatSync(path)` — `Dir.statFile(.{.follow_symlinks=false})`, reuses `__LumenStat`.
- [x] T12 `fs.fstatSync(fd)` — `__fd_table[fd].stat(io)`, reuses `__LumenStat`.
- [x] T13 `fs.fchmodSync(fd, mode)` — `__fd_table[fd].setPermissions(.fromMode(mode))`.
- [x] T14 `fs.fchownSync(fd, uid, gid)` — `__fd_table[fd].setOwner(io, uid, gid)`.
- [~] T15 `fs.chownSync(path, uid, gid)` / `fs.lchownSync(path, uid, gid)` — DROPPED:
  `Dir.setFileOwner` is an unimplemented stub (`@panic("TODO implement
  dirSetFileOwner")`) in this Zig version's `Io.Threaded` backend, plus a
  signature bug in the wrapper itself (declared error set doesn't match what
  it actually returns). Moved to spec.md's "Not planned" table.
- [x] T16 `fs.fsyncSync(fd)` / `fs.fdatasyncSync(fd)` — `__fd_table[fd].sync(io)` (fdatasync aliases fsync).
- [x] T17 `fs.ftruncateSync(fd, len)` — `__fd_table[fd].setLength(io, len)`.
- [x] T18 `fs.futimesSync(fd, atimeMs, mtimeMs)` — `__fd_table[fd].setTimestamps(io, ...)`.
- [x] T19 `fs.utimesSync(path, atimeMs, mtimeMs)` / `fs.lutimesSync(path, ...)` — `Dir.setTimestamps(..., .{.follow_symlinks})`.
- [x] T20 `fs.lchmodSync(path, mode)` — `Dir.openFile(.{.follow_symlinks=false})` + `File.setPermissions`.
- [x] T21 `fs.readdirSync(path) -> string[]` — two-pass `Dir.iterate()` (count, then allocate-exact + fill).
- [x] T22 Verify: one program exercises the whole Phase 3 batch; `zig build test` +
  `zig build conformance` unaffected (a clean, non-concurrent final run showed
  only the 5 known pre-existing failures, none new).
- [x] T23 Update `specs/031-fs-api-expansion/spec.md` coverage count and
  `website/stdlib.html` (quick-jump list + per-function blocks + Planned table).
- [x] T24 Commit, push. Redeploy `lumen-playground` Docker service: in progress.

## Phase 5 (2026-07-02: re-checked three more "blocked" entries rather than
## trusting the old notes, following spec 045's precedent of re-verifying
## assumptions instead of carrying them forward unquestioned)

- [x] T25 `fs.realpathSync(path)` — the "raw libc binding only" note was
  stale; `Dir.realPathFileAlloc` is real and working in this Zig version
  (confirmed by reading `Io/Threaded.zig`'s `dirRealPathFile`, dispatching
  to genuine per-OS implementations, not a stub). Verified against a real
  symlink (resolved to its target) and a nonexistent path (falls back to
  the input unchanged).
- [x] T26 `fs.chownSync(path, uid, gid)` — opens the file first and reuses
  `fchownSync`'s working fd-based `File.setOwner`, sidestepping the
  path-based `Dir.setFileOwner` panic entirely (the same "open, then use
  the file-level method" pattern `chmodSync` already established).
  Verified with a real ownership change confirmed via `stat` (root in the
  dev container). `lchownSync` still isn't achievable this way: it must
  not follow a symlink, and `OpenFileOptions` has no way to open one
  without following it — stays in "Not planned", reason sharpened.
- [x] T27 `fs.writevSync(fd, buffers: string[])` — raw
  `std.os.linux.writev` syscall (`std.Io.File` has no vectored-write
  wrapper, confirmed absent). One real bug hit and fixed:
  `std.os.linux.iovec_const` is a private alias, not the type to actually
  reference — `std.posix.iovec_const` is (found via the debug-preserve
  trick reading the real underlying Zig compiler error). Verified with a
  3-chunk write reassembling correctly from one syscall.
  `readvSync` deliberately not shipped alongside it: Node's `readv` fills
  caller-provided *mutable* buffers, and Lumen's `string` is immutable —
  no natural Lumen shape the way `writevSync`'s (read-only chunks in,
  byte count out) has.
- [x] T28 Investigated whether `fs.realpathSync(".")` gives a real,
  usable cwd string (relevant to `path.resolve`'s long-standing Node-parity
  gap: anchoring a fully-relative result to the real working directory).
  Confirmed yes — matched a real `pwd` exactly. Not wired into
  `path.resolve` this pass: `path.*` functions are pure string
  manipulation today with no `io` parameter at all, and giving one
  function `io` access would be a real signature/architecture change to
  an existing, working call site, not a pure addition like T25-T27.
  Documented as a confirmed-achievable follow-up in `website/stdlib.html`.
- [x] T29 `zig build test` and a full, clean, non-concurrent
  `zig build conformance` run — verify no regressions from T25-T27.
- [x] T30 Updated `specs/031-fs-api-expansion/spec.md` (new Phase 5
  section) and `website/stdlib.html` (quick-jump list, three new
  per-function blocks, Planned table narrowed to `lchownSync`/`readvSync`/
  append-mode `openSync`, stale `fs.realpathSync`-as-blocker references in
  `path.resolve`/`process` cleaned up).
- [x] T31 Commit, push, redeploy `lumen-playground`.

## Phase 6 (2026-07-02, same day: user asked "how to unblock" the Phase 5
## leftovers, then to implement everything verified feasible)

- [x] T32 `fs.lchownSync(path, uid, gid)` — `std.os.linux.lchown` already
  exists as a ready-made raw syscall wrapper (`fchownat` with
  `AT.SYMLINK_NOFOLLOW` under the hood, found by reading `linux.zig`
  directly rather than assuming it didn't exist). Same "raw Linux
  syscall, no libc, no std.Io" shape as `fs.watch`/`writevSync`. Verified
  with a real symlink: the symlink's owner changed via `stat`, its
  target's did not.
- [x] T33 Append-mode `fs.openSync(path, "a")` — re-examined the
  "no seek primitive" assumption by reading `std.Io.File`'s actual write
  path (`fileWriteStreaming` in `Io/Threaded.zig`): it issues a raw,
  position-implicit `writev()` syscall (not `pwritev()`), meaning it uses
  and advances the kernel's own tracked fd offset. So a single raw
  `lseek(fd, 0, SEEK_END)` right after opening (via
  `createFile(.{.truncate = false})`, which creates-or-opens without
  truncating) correctly seats that offset at EOF, and every later
  `writeSync` naturally continues from there -- no seek needed on every
  write, no offset tracking in Lumen code at all. Verified across
  separate open/close cycles: each new `"a"` open correctly re-seeks to
  wherever the file currently ends, not just where it ended at the first
  open.
- [x] T34 `fs.readvSync(fd, sizes: int[]) -> string[]` — reframed rather
  than ported: Node's `readv` fills caller-provided mutable buffers, no
  natural shape given Lumen's `string` is immutable. Takes desired chunk
  sizes instead, allocates and owns the buffers itself, does one real
  `readv` syscall, then hands back immutable strings sliced to what was
  actually read (readv fills earlier buffers completely before later
  ones, so walking the size list against the syscall's total-bytes
  return recovers each buffer's real length). Verified both an exact-fit
  3-chunk read and a short-read case (requested sizes exceeding available
  data, confirming the trailing chunk comes back empty rather than
  garbage or an error).
- [x] T35 `fs.watch`'s event-type distinction — `inotify_event.mask`
  already carried create/modify/delete/rename info, just wasn't being
  read. Listener signature changed from `(string) -> void` to
  `(string, string) -> void`, the second arg `"change"` (data modified)
  or `"rename"` (created/deleted/moved) -- matching Node's own two-value
  `fs.watch` convention, not inotify's full granularity. Verified against
  real file create/write/write/delete: produced exactly
  rename/change/change/rename.
- [x] T36 `zig build test` + a full, clean, non-concurrent
  `zig build conformance` run covering T32-T35 together (path.resolve's
  cwd anchor, spec 032, verified in the same run).
- [x] T37 Updated `website/stdlib.html` (new per-function blocks for
  `lchownSync`/`readvSync`, `fs.watch`'s doc + example signature,
  `openSync`'s append-mode doc, Not-planned table narrowed further).
- [x] T38 Commit, push, redeploy `lumen-playground`.

Remaining genuinely blocked: `fs.opendirSync`/`globSync` (need a
directory-iterator class / real glob algorithm -- same shape as Streams,
just not attempted yet), `fs.promises.*` beyond the async trio (needs
lower-level async op submission), recursive/non-Linux `fs.watch`.

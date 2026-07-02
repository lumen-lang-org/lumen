# Tasks: path API

## Phase 1

- [x] T1 New `pathCallType` in `lumen_check_stdlib.zig` (mirrors `fsCallType`),
  wired into the checker's static-call dispatch the same way `fs`/`Math`/
  `String`/`Promise` are. Also added `"path"` to the parser's
  `isStdNamespace` list (the same gate that recognizes `fs`/`Math`/etc as a
  static-call namespace at parse time).
- [x] T2 `path.basename(path, suffix?)` — `std.fs.path.basename`, strip
  `suffix` if given and present.
- [x] T3 `path.dirname(path)` — `std.fs.path.dirname`, `"."` on `null`
  (deviation from Zig's `null`, matches Node).
- [x] T4 `path.extname(path)` — `std.fs.path.extension`.
- [x] T5 `path.isAbsolute(path)` — `std.fs.path.isAbsolute`.
- [x] T6 `path.normalize(path)` — single-segment `std.fs.path.resolve`.
- [x] T7 `path.join(...paths)` (2-6 args) — naive `std.fs.path.join` piped
  through a single-segment `resolve` to collapse `.`/`..`.
- [x] T8 `path.resolve(...paths)` (1-6 args) — `std.fs.path.resolve`; document
  the no-real-cwd-anchor deviation inline where it's emitted.
- [x] T9 `path.parse(path)` — registers `__LumenPathParts` record type
  (`root`, `dir`, `base`, `name`, `ext`), assembled from
  `dirname`/`basename`/`extension`.
- [x] T10 `path.format(parts)` — record-typed parameter (all 5 fields
  required, a documented deviation from Node's optional fields), Node's
  dir/base-over-root/name+ext precedence.
- [x] T11 `path.sep()` / `path.delimiter()` — zero-arg functions, not
  properties (deviation: no static-namespace constant-property mechanism
  exists yet).
- [x] T12 Verify: one program exercises all 11 together; output cross-checked
  against `node -e` for the same inputs — all 20 checks matched exactly.
- [x] T13 `zig build test` passes. `zig build conformance` run alongside the
  Phase 3 fs batch (see `specs/031-fs-api-expansion/tasks.md`); no new
  failures from either body of work.
- [x] T14 Updated `website/stdlib.html`: new `path` quick-jump list + per
  function blocks (mirroring the `fs` section); moved `path.*` out of the
  Planned table (`relative`/`matchesGlob`/win32 variants remain, correctly).
- [x] T15 Commit, push. Redeploy `lumen-playground`: in progress.

## Phase 2 (2026-07-02)

- [x] T16 `path.resolve`'s Node-parity cwd anchor: gave `__pathResolve` an
  `io` parameter (the one `path.*` function to get one -- every other one
  stays pure string manipulation) and prepended the real cwd, obtained via
  `std.process.currentPath` (the same mechanism `process.cwd()` already
  used, discovered while investigating -- turns out this was never
  genuinely blocked by the `fs.realpathSync` gap the old notes pointed to,
  since `process.cwd()` used a different mechanism from the start). Bug
  hit and fixed: `std.process.currentPath` returns the written length as
  a `usize`, not a `[]const u8` slice directly -- needed `cwd_buf[0..n]`.
  Verified: `path.resolve("foo", "bar")` now returns `<cwd>/foo/bar`; an
  absolute segment still resets the result exactly as before.
- [x] T17 `zig build test` + a full, clean, non-concurrent
  `zig build conformance` run alongside the spec 031 phase 5 batch — no
  regressions.
- [x] T18 Updated `website/stdlib.html` and `spec.md`'s deviation section
  and Not-planned table.
- [x] T19 Commit, push, redeploy `lumen-playground`.

## Phase 2 / deferred (tracked, not scheduled)

- `path.relative(from, to)` — not attempted; `path.resolve`'s cwd access
  (T16 above) removes what used to be the blocker, a real follow-up now.
- `path.matchesGlob` — blocked on no glob algorithm (same as `fs.globSync`).
- `path.win32` / `path.posix` / `path.toNamespacedPath` — out of scope,
  POSIX-only target.

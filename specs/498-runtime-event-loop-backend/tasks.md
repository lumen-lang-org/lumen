# Tasks: The event-loop backend is chosen at run time

## Investigation

- [x] Confirm the failing syscall. Straced under docker's default profile:
      one `io_uring_setup`, EPERM, immediate abort. Under
      `seccomp=unconfined` the same call returns a ring and the program runs.
- [x] Confirm the blast radius is async programs, not all programs. The
      preamble is gated on `program.needs_async`; a sync binary links no
      libxev and runs under every profile tested.
- [x] Confirm the unwrap is incidental rather than deliberate. The emitted
      `init()` is declared `void`, so there was no error path for
      `catch unreachable` to be a shortcut past; libxev's `Loop.init` returns
      `!Loop` and propagates the error correctly.
- [x] Confirm libxev already ships runtime selection (`Dynamic`, `detect()`,
      `prefer()`, and an io_uring `available()` that probes with a real
      `IoUring.init`) and that nothing in the compiler or in libxev's
      `build.zig` exposed a way to reach it.
- [x] Confirm the epoll backend could not do file I/O for us: it routes
      `pread`/`pwrite` through a thread pool the loop was never given, and
      then files the resulting error under the wrong union field, so the
      symptom is a union-access panic rather than `ThreadPoolRequired`.
- [x] Establish a before/after baseline rather than a single run. Three
      programs (timer only, async file I/O, both interleaved) across three
      profiles, all three failing before the change.

## Implementation

- [x] Generated source selects `Dynamic` where the platform has more than
      one candidate and the package root where it has one, so single-backend
      platforms keep exactly the code they had.
- [x] `LumenLoop.init` calls `detect()` before any watcher is initialized.
- [x] The loop is always given a thread pool; epoll needs one for file I/O
      and io_uring never schedules on it.
- [x] The blocking-fs plumbing shares that pool instead of standing up a
      second one.
- [x] `catch unreachable` replaced with a diagnostic naming the backend, the
      candidates, the error and the usual cause.
- [x] `LUMEN_EVENT_BACKEND` names a backend explicitly; an unusable name is
      an error, not a silent fallback.
- [x] `LIBXEV_PATCHES` carries the epoll union-field fix, applied to the
      fetched tree, failing the build loudly if it ever stops applying.
- [x] `LIBXEV_PATCH_REV` stamped into the extraction and checked on reuse, so
      an older cached tree is re-fetched rather than reused unpatched.
- [x] `docs/CODEMAP.md` regenerated (`sh tools/codemap.sh`).

## Verification

- [x] `zig build` passes.
- [x] `zig build test` passes.
- [x] `zig build conformance`: 302 passed, 20 failed -- and the failure set
      is *identical*, case for case, to the same command on an unmodified
      `main` checkout (302/20). Every one of the twenty predates this slice;
      nineteen are `*.invalid.*` diagnostics cases, which no event-loop
      change can reach, and the twentieth
      (`inherit.valid.inheritance`, "use of undeclared identifier
      'VT_Named'") reproduces on `main` with the identical message.
- [x] `zig fmt --check` clean on every file this slice touches. (`zig build
      fmt-check` fails on `src/lumen_check.zig` and
      `src/lumen_check_meta.zig`, which this slice does not touch and which
      fail identically on `main`.)
- [x] Every conformance manifest re-run with `LUMEN_EVENT_BACKEND=epoll`, so
      the whole language surface is exercised on the fallback backend: 52
      manifests, 303 passed, 22 failed. The failure set is the twenty above
      plus the two cases of `479-suspending-await`, which `build.zig` does
      not wire into the `conformance` step and which fail identically on
      io_uring -- async functions run eagerly there rather than suspending,
      on either backend. No case behaves differently between the two.
- [x] Timer, async-file-I/O and interleaved programs each run under
      `seccomp=unconfined`, docker's default profile, and a profile
      allowlisting no `io_uring*` syscall.
- [x] Straced: unconfined selects io_uring and never calls `epoll_create1`;
      under the default profile `io_uring_setup` returns EPERM and the
      program continues on `eventfd2` + `epoll_create1`.
- [x] Under a profile that blocks both backends, the diagnostic prints and
      the process exits 1, in place of the unwrap panic.
- [x] A cross-compiled build for a single-candidate target still compiles,
      exercising the collapsed-`Dynamic` branch.
- [x] Deleting the patch stamp re-fetches and re-patches; corrupting the
      patch text fails the build with a message naming the file and pointing
      at `LIBXEV_PATCHES`.

## Follow-up (not this slice)

- [ ] `LumenLoop.driveUntil` swallows a loop error (`run(.once) catch break`)
      and returns whatever the promise held. That predates this slice and is
      not backend-specific, but it is the next thing in this file that turns
      a real failure into a wrong answer rather than a message.
- [ ] The io_uring `available()` probe costs one extra `io_uring_setup` and
      close per process start. Cheap, but it is a real regression on the
      default path if some caller ever starts many short-lived processes.

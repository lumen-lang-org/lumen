# Feature Specification: The event-loop backend is chosen at run time

## Problem

An async Lumen binary cannot start where io_uring is unavailable. The failure
is total and immediate:

```
$ docker run --rm ubuntu:24.04 ./app        # docker's DEFAULT seccomp profile
app.ts:0:0: runtime error: attempt to unwrap error: PermissionDenied
```

Five lines of source are enough to reproduce it:

```ts
function tick(): void { console.log("timer-fired"); }
setTimeout(tick, 50);
console.log("async-start");
```

`io_uring_setup` is not in docker's default syscall allowlist. It returns
EPERM, and the first statement of generated `main` -- `LumenLoop.init()` --
turns that into a panic. A container is the ordinary place to run a compiled
binary, so "async programs do not run in containers" is close to the whole of
the problem.

Two things stack up to produce it.

**The backend was bound at compile time.** The generated source imported
libxev's package root, which binds `Backend.default().Api()`: io_uring on
Linux, decided when the *compiler* was built, on a machine where io_uring
worked. Nothing in the binary could reconsider that.

**The failure had no error path to take.** The emitted preamble read

```zig
fn init() void { __xev_loop = xev.Loop.init(.{}) catch unreachable; }
```

Declared `void`, so `catch unreachable` was not a shortcut past an existing
error path -- there was none. libxev propagates the error properly
(`Loop.init` returns `!Loop`); the unwrap is ours, and it reports a
`PermissionDenied` with no hint of which subsystem asked for what.

Sync programs are unaffected: the preamble is emitted only under
`program.needs_async`, and a sync binary links no libxev at all.

## Scope

In scope:

- Choosing the event-loop backend at run time: io_uring where the system
  allows it, epoll otherwise.
- Giving the loop a thread pool, without which the epoll backend cannot do
  file I/O at all.
- A real diagnostic when no backend can start, naming what was tried and why
  it failed.
- `LUMEN_EVENT_BACKEND` to name a backend explicitly.
- Carrying a fix against pinned libxev's epoll backend, which files two
  errors under the wrong union field and turns a diagnosable failure into an
  unrelated-looking panic.

Out of scope:

- Any change to what async programs *can* do. The two backends are meant to
  be indistinguishable from the language; where they are not, that is a bug
  in this slice, not a documented difference.
- Non-Linux platforms. macOS, Windows and WASI each have exactly one
  candidate backend and are deliberately left on precisely the code they were
  on before.
- Reporting which backend was chosen to the program. Nothing has asked, and a
  program that behaves differently on one is a bug we would rather find than
  let a caller work around.

## Design

### Selection

libxev already ships the mechanism: `Dynamic` exposes the same API as the
static one but keeps the backend in a variable, with `detect()` probing
candidates in order (on Linux: io_uring, then epoll) and `prefer()` for an
explicit choice. io_uring's `available()` is exactly the right probe -- it
attempts a real `IoUring.init` and reports a bool, so a seccomp EPERM reads
as "unavailable" rather than as a crash.

The generated source picks between the two APIs itself:

```zig
const xev = if (@import("xev").Dynamic.dynamic) @import("xev").Dynamic else @import("xev");
```

Where a platform has more than one candidate, `Dynamic` is a distinct type
and `dynamic` is `true`. Where it has one, `Dynamic` *collapses to that
backend's static API*, whose `dynamic` is `false` and which does not forward
`ThreadPool` -- so on macOS, Windows and WASI the package root is both the
right type and the same behaviour it always had. Deciding this in the
generated source rather than in the compiler keeps it a property of the
target being built for, not of a triple the compiler had to interpret.

`LumenLoop.init` then calls `detect()` before anything else touches libxev.
That ordering is not incidental: every watcher (`Timer`, `Async`, `File`)
reads the selected backend when it is initialized, and `Dynamic` starts on a
candidate it has not probed.

### A thread pool, always

epoll has no completion-based file I/O. libxev's epoll backend routes
`pread`/`pwrite` through a thread pool and fails the operation outright when
the loop was not given one, so an epoll-backed `fs.readFile` did not work at
all. The loop is now always constructed with a pool.

The io_uring path pays nothing for it. `ThreadPool.init` only records
configuration; threads are spawned on first schedule, and io_uring never
schedules anything on it.

The blocking-fs plumbing (`unlink`, `mkdir`, `rmdir`, `stat` -- operations no
backend has an async primitive for) now runs on that same pool instead of
standing up a second one. A program needing it is asynchronous by definition,
so the loop's pool always exists by the time it is used.

### When nothing works

`catch unreachable` becomes a diagnostic that says which backend was tried,
what the candidates were, what the error was, and what usually causes it:

```
lumen: could not start the async event loop
  backend:    epoll
  candidates: io_uring, epoll
  error:      Unexpected
  This program is asynchronous, so it needs an event-loop backend the
  system will let it start. A sandbox or seccomp profile that blocks a
  backend's syscalls is the usual cause: io_uring needs io_uring_setup
  and io_uring_enter, epoll needs epoll_create1, epoll_ctl, epoll_pwait
  and eventfd2.
```

### `LUMEN_EVENT_BACKEND`

Names a backend explicitly, bypassing the probe. A name that is not a
candidate of this build, or not available here, is an error rather than a
silent fallback: someone who named a backend wants to know they did not get
it.

Its real job is testing. Without it the epoll path can only be exercised
inside a sandbox, which no test in this repository can build; with it, the
entire conformance suite runs on either backend on an ordinary host.

### The libxev carry

libxev's epoll backend stores the error from a failed `thread_schedule` --
and from a failed `fd_maybe_dup` or `epoll_ctl` -- into the wrong field of
the result union: `.read` in the `pread` prong, `.write` in the `pwrite`
prong. The caller reads the field it asked for, so instead of the error the
program dies with

```
runtime error: access of union field 'pwrite' while field 'write' is active
```

which points nowhere near the cause. This is what made the missing thread
pool hard to see.

libxev is not vendored: the compiler fetches the pinned commit at build time
and caches it. The fix is carried as an exact-text patch applied to that
extraction (`LIBXEV_PATCHES` in `src/lumen.zig`), for three reasons.

- Attaching a thread pool makes the buggy lines unreachable *today*, but a
  latent mis-filed union is exactly the thing that resurfaces later as an
  unrelated panic. "We never hit it" is not a fix.
- The patch is applied to the download, so the repository stays free of a
  vendored copy of a dependency.
- A patch that does not apply is a **hard error**, not a warning. That is how
  the next person to bump `LIBXEV_COMMIT` learns this carry exists: from a
  build that fails and names the file, rather than from a program that
  misbehaves months later.

The extraction is stamped with `LIBXEV_PATCH_REV` and the stamp is checked on
reuse, so a tree left behind by an older compiler -- unpatched, or patched
differently -- is re-fetched rather than silently reused. Each patched region
also carries a comment in the extracted source saying what it is and pointing
back here.

## Success Criteria

1. An async program built by this compiler runs under docker's default
   seccomp profile, selecting epoll.
2. The same under a stricter profile that allowlists no `io_uring*` syscall.
3. Async *file* I/O -- `readFile`, `writeFile`, `appendFile` -- works on the
   epoll path.
4. On an io_uring-capable host the default path still selects io_uring, and
   the existing suite is unchanged.
5. Where no backend can start, the program says so, naming the backend, the
   candidates and the error, instead of panicking on an unwrap.
6. `LUMEN_EVENT_BACKEND=epoll` runs the whole conformance suite on epoll,
   with no case behaving differently from the io_uring run.

## Notes

Verified on Linux 6.8 with docker 29.1.3, straced under each profile:
unconfined gives `io_uring_setup` and no `epoll_create1`; under the default
profile `io_uring_setup` returns EPERM and the program continues on
`eventfd2` + `epoll_create1`.

One measurable cost on the io_uring path: `available()` probes by creating
and tearing down a real ring, so startup now performs one extra
`io_uring_setup`/`close` pair. `LUMEN_EVENT_BACKEND=io_uring` skips the
probe for anyone who cannot afford it.

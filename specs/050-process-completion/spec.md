# Feature Specification: process API completion

**Feature Branch**: `main` (milestone 050) | **Status**: Draft

**Input**: Spec 033 shipped `process`'s Phase 1 (cwd/chdir/exit/env/platform/
arch/pid/argv) and explicitly deferred a "Phase 2 / Not planned" table:
`hrtime`/`uptime` ("needs a recorded process-start timestamp; no
high-resolution timer wiring yet"), `memoryUsage`/`resourceUsage`/`cpuUsage`
("low value ... revisit if requested"), `kill`/signal events ("no event/
listener infrastructure yet"), the `uid`/`gid` family ("revisit only if
requested"), `version`/`versions`/`release`/`config`/`features` ("Node-
specific build metadata; not meaningful for Lumen"), `stdout`/`stdin`/
`stderr`, and `umask`/`abort`/`title`/`execPath`/`argv0`/`mainModule`
("niche/process-replacement-level operations, low value right now").

Two of 033's blockers no longer hold: spec 041 shipped `time.now()`/
`time.monotonic()`, which wires up exactly the high-resolution timer
primitive (`std.Io.Clock.now(...)`) that `uptime()`/`hrtime()` were blocked
on; and this milestone has been explicitly asked for, which is what "revisit
if requested" was waiting on for the `uid`/`gid` family. This spec re-checks
every "Not planned" line from 033 rather than assuming the old verdict still
holds, the same diligence 033 itself applied to older ljs-era assumptions.

## Scope

### Phase 1 (this milestone)

| Function | Signature | Primitive |
| --- | --- | --- |
| `process.uptime()` | `() -> number` | A start timestamp (`std.Io.Clock.now(.awake, io)`, the same clock spec 041's `time.monotonic()` uses) is recorded once in `main()`, into a new file-scope `__process_start_ns: i64`. Each call subtracts and converts to fractional seconds. |
| `process.hrtime()` | `() -> i64` | Same `.awake` clock, returned as raw nanoseconds (no division). See "hrtime shape" below for why this is a scalar, not Node's `[seconds, nanoseconds]` tuple. |
| `process.memoryUsage()` | `() -> { rss: i64, vsize: i64 }` | A plain read of `/proc/self/status` via the same `std.Io.Dir.cwd().readFileAlloc` primitive `fs.readFileSync` already uses, then a text scan for the `VmRSS:`/`VmSize:` lines (values in kB in that file; multiplied by 1024 for bytes). |
| `process.kill(pid, signal)` | `(int, string) -> bool` | `std.posix.kill(pid, sig)` where `sig` is `std.os.linux.SIG`, resolved from the `signal` string via `std.meta.stringToEnum` (accepts both `"SIGTERM"` and `"TERM"`). Returns whether the syscall succeeded. |
| `process.umask()` | `() -> int` | The classic POSIX read-without-changing trick: `umask(0)` returns the old mask, then immediately `umask(old)` restores it. Raw syscall (`std.os.linux.syscall1(.umask, ...)` — Zig has no wrapped `std.posix.umask`). |
| `process.setUmask(mask)` | `int -> int` | One raw `umask(mask)` syscall; returns the *previous* mask, matching what the real syscall itself returns (Node's `process.umask(mask)` setter form does the same). Two names, not one overloaded call — see "get/set naming" below. |
| `process.getuid()` / `getgid()` / `geteuid()` / `getegid()` | `() -> int` | `std.os.linux.getuid()` / `getgid()` / `geteuid()` / `getegid()` — raw syscalls, same shape as the existing `process.pid()`. POSIX-only, see below. |
| `process.abort()` | `() -> void` | `std.process.abort()` — already implemented as a raw `noreturn` (raises `SIGABRT` then `SIGKILL` without needing libc; only calls into `std.c.abort` if libc happens to be linked, which Lumen binaries never are). |
| `process.version()` | `() -> string` | A hardcoded `LUMEN_VERSION` constant. **Not Node's version** — see "version marker" below. |

All nine follow the established three-file pattern: a `processCallType`
branch in `lumen_check_stdlib.zig`, an emit branch in `lumen_emit.zig`, and
runtime codegen appended inside the existing `if (program.needs_process_api)`
block in `lumen_compiler.zig` (the same coarse-grained, whole-namespace-in-
one-block shape `os`'s block already established — not a new per-function
flag for each one, since Zig only semantically analyzes a function body when
it's actually called, so unused helpers in the same block cost nothing).
`process.uptime()` additionally needs its own `program.needs_process_uptime`
flag, because (unlike every other function in this block) it requires code
to run unconditionally in `main()` before any user code — recording the
start timestamp — which the other functions don't need and shouldn't pay for
when `uptime()` isn't called.

### hrtime shape: scalar `i64` nanoseconds, not a `[seconds, nanoseconds]` tuple

Node's `process.hrtime()` returns a two-element array specifically because
JavaScript numbers are IEEE-754 doubles that can't exactly represent a
nanosecond-precision epoch-scale value — splitting into whole seconds plus a
sub-second nanosecond remainder is a workaround for that limitation.
Investigated whether Lumen's real, working `tuple_type` (`[A, B]` syntax,
lowered to a nominal Zig struct per spec's `tupleStructName`) could
represent this cleanly. It could represent the *shape*, but every existing
use of `tuple_type` in this codebase is a user-written tuple literal
(`tuple_lit` in the AST) — no stdlib function has ever constructed one as a
call return value, so this would be first-of-its-kind plumbing with no
working precedent to copy, for a workaround Lumen doesn't need in the first
place: Lumen's `i64` is a real 64-bit integer (not a double), so it doesn't
have JavaScript's precision problem. A raw nanosecond count fits in `i64`
for about 292 years without overflow or precision loss — there's no reason
to split it. This mirrors spec 041's exact reasoning for why `time.now()`/
`time.monotonic()` are `i64` milliseconds rather than anything split, and
matches where Node itself ended up later: `process.hrtime.bigint()` (added
in Node 10) returns a single scalar nanosecond `BigInt` for this identical
reason, and is the form Node's own docs now recommend over the legacy tuple
form. `process.hrtime()` here is effectively that scalar form.

### get/set naming: `umask()` / `setUmask(mask)`, not one overloaded call

Node's `process.umask([mask])` dispatches on argument count: zero args
reads, one arg sets. Lumen's checker has no call-site overloading — every
`processCallType` branch fails with `E_ARG_COUNT` on anything but its one
fixed arity (see `cwd()` vs. `chdir(directory)` already being two names
instead of one arity-dispatched `cwd([directory])`, the same shape this
follows). Checked the rest of the stdlib for an established get/set-pair
naming convention to match rather than inventing one: there isn't one (`os`
and `fs` have no getter/setter pairs at all, just one-directional reads or
one-directional writes), so this introduces the first one, following the
task's own suggested fallback shape: `umask()` for the getter,
`setUmask(mask)` for the setter.

### `getuid`/`getgid`/`geteuid`/`getegid`: POSIX-only

Like `process.pid()` already is, these are raw Linux syscalls
(`std.os.linux.getuid()` etc.) with no Windows equivalent — consistent with
Lumen's existing POSIX-only posture (no `os.win32`, no `path.win32`). Under
`--wasm` (WASI has no uid/gid concept) they return `0`, the same fallback
`process.pid()` already uses on non-Linux targets, gated by the identical
`if (@import("builtin").os.tag != .linux) return 0;` guard.

### `memoryUsage()`: which `/proc/self/status` fields are real

Checked `/proc/self/status` by hand on the dev box before committing to a
field list (`cat /proc/self/status | grep -i vm` while building this spec)
rather than guessing: `VmSize` (virtual memory size), `VmRSS` (resident set
size — the physical memory actually in use), `VmHWM` (peak RSS), and
`VmData` (data segment size) are all present and trivially parseable, each
as `Label:<whitespace>NUMBER kB`. Chose `rss` and `vsize` as the two fields
that map onto genuinely standard, well-understood process metrics (matching
Node's own `rss`, and `vsize`/`VmSize` is the direct analogue of what `ps`
calls `VSZ`). Deliberately did **not** invent `heapTotal`/`heapUsed`/
`external`/`arrayBuffers` fields the way Node's shape has them: those
describe V8's garbage-collected heap, which has no Lumen-side equivalent
(Lumen has no GC, no heap introspection) — faking those fields with a
made-up or zeroed value would be actively misleading rather than an honest
gap. Both fields are `i64` bytes, not `int`: an `int`-truncated RSS would
repeat the exact tradeoff spec 034 already flagged for `os.totalmem()`/
`freemem()` (`int` truncates past ~2GB) instead of avoiding it the way spec
041 chose `i64` for `time.now()`. Any process pushing >2GB RSS with an
`int`-truncated field would silently look tiny; there's no reason to
reintroduce that bug in a brand-new field when `i64` (already a real,
usable Lumen type) avoids it outright.

### `kill(pid, signal)`: string signal name, not a raw int

Investigated both shapes the task allowed. A plain `int` signal number
would be the simpler checker/emit diff (no string-to-enum mapping), but it
pushes every caller to memorize magic numbers (`9` for `SIGKILL`) that are
neither self-documenting nor validated at compile time. A `string` name
(`"SIGTERM"`) is what essentially every real call site actually writes
(including Node's own `child.kill("SIGTERM")` convention) and reads
correctly at the call site without a lookup table in the caller's head.
Considered (but did not build) a checker-enforced string-literal-union type
the way `type X = "a" | "b"` aliases already work elsewhere in this
compiler: that would reject typos at compile time, which is strictly
better, but would be the first time a *built-in* stdlib parameter (as
opposed to a user's own `type` declaration) is typed as a literal union,
and would need its own synthetic registration path with no precedent to
follow. Deferred that tightening for a future pass; this milestone accepts
a plain `string` and resolves it at runtime via `std.meta.stringToEnum`
against `std.os.linux.SIG` (after stripping an optional leading `"SIG"`, so
both `"SIGTERM"` and `"TERM"` work). An unrecognized name resolves to
signal `0` — POSIX's "null signal", which performs the permission/existence
check but delivers nothing destructive — rather than silently mapping a
typo to some other real, destructive signal.

### `version()`: Lumen's own marker, not Node's

Searched the repository for an existing version constant before inventing
one: `build.zig.zon`'s `.version = "0.0.0"` is explicitly a placeholder per
its own comment (`"In a future version of Zig it will be used for package
deduplication"` — not a tracked product version), there is no `--version`
CLI flag on `lumen` today, and no version string appears anywhere else in
`src/`. The repository *does* use real git tags (`v0.0.1` through the
current `v0.3.1`), so `process.version()` returns a hardcoded
`LUMEN_VERSION = "0.3.1"` constant matching the latest tag at the time of
this milestone. This has to be bumped by hand alongside future tags — there
is no automated wiring from git metadata into the generated binary (that
would need `build.zig` changes to thread a `-D` option through to codegen,
out of scope for a stdlib completion pass). Flagged here explicitly rather
than silently stale.

### Phase 2 / Not planned (re-checked, still blocked)

| Function | Blocker |
| --- | --- |
| `process.stdout`/`stdin`/`stderr` (Stream objects) | no `Stream` abstraction in the language (unchanged from 033; documented in `website/stdlib.html`'s existing gap list) |
| `process.on(event, ...)`, signal events (`SIGINT` handlers, ...) | still no event/listener infrastructure — `process.kill()` shipping this pass sends a signal, but nothing in the generated binary can *receive and dispatch* one back into user code; that's a real, separate event-loop-integration feature, not a small follow-up |
| `process.nextTick(fn)` / microtask scheduling | investigated only briefly, after everything else above shipped and verified, to honor the task's own "don't let it block or risk the rest" instruction — see notes below; not shipped this pass |
| `process.resourceUsage()`, `process.cpuUsage()`, `process.threadCpuUsage()` | still no per-thread/per-process CPU-time accounting primitive vetted (`getrusage` is a plausible raw syscall candidate, same posture as `os.getPriority()`'s deferral in spec 034, but wasn't vetted this pass — `memoryUsage()` covers the highest-value single field; the rest stay deferred rather than rushed) |
| `process.send()`, `.disconnect()`, `.channel`, `.connected` (IPC) | still no persistent child-process channel — `child_process.spawnSync` (spec 037) is a synchronous one-shot with no persistent pipe wired up |
| `process.report.*`, `process.permission.*`, `process.finalization.*` | advanced/niche Node-internals surface, out of scope |
| `process.versions`, `process.release`, `process.config`, `process.features.*` | Node-build-metadata specific (V8 version, OpenSSL version, ICU, ...); none of it is meaningful for a Zig-backed compiled language. `process.version()` itself ships this pass as a distinct, Lumen-specific marker — this line is only about the *other* Node-build-metadata properties |
| `process.title`, `.execPath`, `.argv0`, `.mainModule`, `.dlopen`, `.execve` | niche/process-replacement-level operations; `argv0` is technically a one-liner (`process.argv()[0]`) but adds a redundant accessor for something already reachable, so left out |

## Requirements

- **FR-001**: Each Phase 1 function follows the established stdlib pattern
  described in the Scope section: a `processCallType` branch, an emit
  branch, and runtime codegen in the existing `needs_process_api` block
  (plus the new `needs_process_uptime` flag for `uptime()`'s start-time
  init).
- **FR-002**: No `-lc` linking required for any Phase 1 function — every
  primitive used (`std.Io.Clock`, `std.Io.Dir.cwd().readFileAlloc`,
  `std.posix.kill`, `std.os.linux.syscall1(.umask, ...)`,
  `std.os.linux.getuid/getgid/geteuid/getegid`, `std.process.abort`) is
  either already used elsewhere in this compiler or a raw Linux syscall,
  matching the posture of every prior process/os spec.
- **FR-003**: Failures swallow to a safe default, consistent with the rest
  of the stdlib's no-exceptions-yet posture: `memoryUsage()` returns `0` for
  a field it can't parse, `kill()` returns `false` on any `posix.kill`
  error, `getuid`-family functions return `0` on non-Linux targets.
- **FR-004**: Existing stdlib namespaces and all other language features
  MUST be unaffected (regression-checked via `zig build test` and
  `zig build conformance`).

## Success criteria

- **SC-001**: A program exercising all nine functions together compiles and
  runs. Each result is cross-checked against real, independently observed
  system state (not just "the syscall didn't error"):
  - `uptime()` sampled twice with a sleep in between, confirming monotonic
    increase and a plausible small magnitude.
  - `hrtime()` sampled twice, confirming monotonic increase in nanoseconds.
  - `memoryUsage().rss` cross-checked against `ps -o rss= -p <pid>` /
    `/proc/<pid>/status` read from the *outside* while the process is
    running (via a short sleep so the external read can catch it), not just
    self-consistency.
  - `kill()` verified by actually spawning a real child process (a small
    helper `.ts` compiled separately, or a shell `sleep`) and confirming it
    received and acted on the signal (process disappears from `ps`/exits
    with the expected signal-terminated status) — not just "the syscall
    returned true".
  - `umask()`/`setUmask()` cross-checked against the shell's own `umask`
    builtin before and after.
  - `getuid()`/`geteuid()` cross-checked against `id -u`; `getgid()`/
    `getegid()` against `id -g`.
  - `abort()` verified in a separate single-purpose program (it terminates
    the process, so it can't share a run with the other checks): confirmed
    the process actually dies with `SIGABRT` (checked via the shell's `$?`
    exit-status convention, `128 + signal number`).
  - `version()` checked to return the expected hardcoded string.
- **SC-002**: `zig build test` and `zig build conformance` are unaffected
  (no new failures beyond whatever pre-existing failures already exist on
  `main`).

## Notes

`process.nextTick(fn)` was investigated briefly per the task's explicit
"only if you have time left, don't let it block or risk the rest"
instruction. Lumen's async machinery (spec 022) already has a microtask-like
queue driving `Promise`/`await` resolution and a timer queue (`setTimeout`)
via `LumenLoop`. A `nextTick`-shaped API would need a callback value type
compatible with that queue and a decision about whether it callable outside
an `async` context at all (Node's `nextTick` works even in fully sync-looking
top-level code because Node always has an event loop running; a Lumen
program with no `async` anywhere never starts `LumenLoop` at all today). That
last question — what happens when `nextTick` is called in a program with no
other async machinery running — is a real design decision, not a
mechanical follow-up, so it's left out of this pass entirely rather than
rushed.

# Tasks: process API completion

## Phase 1

- [x] T1 `process.uptime()` — new `needs_process_uptime` flag; `__process_start_ns`
  global set once in `main()`; `__processUptime(io)` computes fractional
  seconds since start. Verify: two samples with a sleep between show a
  plausible, monotonically increasing value.
- [x] T2 `process.hrtime()` — `__processHrtime(io)`, raw nanoseconds from the
  `.awake` clock (scalar, not a tuple — see spec's "hrtime shape" section).
  Verify: two samples show monotonically increasing nanoseconds.
- [x] T3 `process.memoryUsage()` — `__LumenProcessMemory { rss: i64, vsize: i64 }`
  record (registered the same way `registerLumenStat` registers
  `__LumenStat`); `__processMemoryUsage(io, alloc)` reads
  `/proc/self/status`, parses `VmRSS:`/`VmSize:` lines. Verify: cross-check
  `rss` against an external `ps -o rss=`/`/proc/<pid>/status` read while the
  process is alive.
- [x] T4 `process.kill(pid, signal)` — `__processKill(pid, signal)`, string
  signal name resolved via `std.meta.stringToEnum` against
  `std.os.linux.SIG`, unknown name -> signal 0. Verify: spawn a real child
  process, kill it, confirm it actually died (not just a non-error return).
- [x] T5 `process.umask()` / `process.setUmask(mask)` — raw
  `std.os.linux.syscall1(.umask, ...)`. Verify: cross-check against the
  shell's own `umask` builtin before/after.
- [x] T6 `process.getuid()` / `getgid()` / `geteuid()` / `getegid()` — raw
  `std.os.linux.get{u,g}id`/`gete{u,g}id`. Verify: cross-check against
  `id -u`/`id -g`.
- [x] T7 `process.abort()` — `std.process.abort()`. Verify in an isolated
  program: process exits via `SIGABRT` (shell `$?` == 134).
- [x] T8 `process.version()` — hardcoded `LUMEN_VERSION` constant matching
  the latest git tag. Verify: returns the expected string.
- [x] T9 One combined verification program exercising uptime/hrtime/
  memoryUsage/umask/setUmask/getuid family/version together (kill and abort
  verified separately since they affect process lifecycle).
- [x] T10 `zig build test` passes. Clean, non-concurrent `zig build
  conformance` run shows no new failures vs. `main`.
- [x] T11 Update `website/stdlib.html`: extend the `process` quick-jump list
  and per-function `<div class="api">` blocks; update the Planned/Not-planned
  table to move shipped functions out and reflect the re-checked blockers.
- [x] T12 Commit (no push).

## Deferred (tracked, not scheduled)

See spec.md's "Phase 2 / Not planned" table: `stdout`/`stdin`/`stderr`
streams, `process.on`/signal-handling events, `nextTick`/microtask
scheduling, `resourceUsage`/`cpuUsage`/`threadCpuUsage`, IPC
(`send`/`disconnect`/`channel`), `report.*`/`permission.*`/`finalization.*`,
`versions`/`release`/`config`/`features`, and
`title`/`execPath`/`argv0`/`mainModule`/`dlopen`/`execve`.

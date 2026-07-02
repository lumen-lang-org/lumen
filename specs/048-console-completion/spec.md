# Spec 048: console completion

## Goal

Cover the rest of [Node's `console` module](https://nodejs.org/api/console.html)
that's practical to add without a bigger, separate feature (indentation state,
structured object formatting, a `Console` class/custom-stream constructor).
Lumen currently only has `console.log(x)`/`console.error(x)`, each a
dedicated AST node (`ConsoleLog` in `lumen_ast.zig`), not an ordinary
`fsCallType`-style static-namespace call -- unlike `fs.*`/`http.*`/etc, a
`console.log` argument is genuinely `any`-typed (its printed representation is
inferred from whatever expression is passed), which the static per-function
namespace-call machinery (fixed argument types per function name) doesn't
model directly.

## A real pre-existing bug found and fixed as part of this pass

Before this spec, `console.log` and `console.error` **both** printed to real
stderr, not stdout/stderr respectively as Node does. The emitter used
`std.debug.print` unconditionally for every `console.*` call regardless of
`.method` -- and Zig's `std.debug.print` always targets stderr (it locks and
writes to fd 2 directly; there's no stdout variant). Verified directly before
touching any code:

```
$ ./prog 2>/dev/null   # (prog just does console.log("hello-log"); console.error("hello-error");)
$ ./prog 1>/dev/null
hello-log
hello-error
```

Both lines vanished when stderr was redirected and both showed up when stdout
was redirected -- conclusive proof everything was on fd 2. This was silent
because nothing in the compiler ever checked `.method` at the emit level (the
struct's own doc comment plus this spec's originating task both assumed a
stdout/stderr split existed already; grepping `lumen_emit*.zig` for
`"error"`/`stdout`/`stderr` turned up nothing). Fixing this is a prerequisite
for `console.warn`/`info`/`debug`/`trace`, since "same routing as
`console.error`" / "same routing as `console.log`" only means something once
`console.log` and `console.error` actually route differently.

**Fix**: `console.log`/`info`/`debug` now go through a new `__consoleOut`
runtime helper backed by `std.Io.File.stdout().writer(__io, buf)` (the same
`std.Io`-based file-writer pattern the compiler CLI itself already uses for
its own stderr messages, and the same shape as the http server's per-connection
`stream.writer(io, buf)`). `console.error`/`warn`/`trace` keep using
`std.debug.print` directly (real stderr, zero behavior change from before
except now genuinely isolated from stdout). This routes `console.log`
through `__io` for the first time, so any program using only `console.log`
now needs the `uses_io` prologue (`main(__init: std.process.Init) !void`,
`__io`/`__alloc` globals) -- harmless; dozens of other stdlib entry points
already require it.

**Collateral fix**: the legacy (frozen, spec 001-028) conformance harness
(`tools/lumen_conformance.zig`) had baked in the bug -- `checkCompileRun`
compared a case's `expect.stdout` field against `run.stderr`, because that's
where output actually landed before this fix. Changed it to concatenate
`run.stdout` and `run.stderr` for the comparison instead of picking one
statically, so it keeps working correctly regardless of which real stream a
given case's output lands on, without editing any of the ~90 existing
manifest cases (only one of which, `console-stdlib.ts`, uses
`console.error`, and does so as its only statement, so stream-interleaving
order is a non-issue).

## API (this pass)

| Function | Stream | Notes |
| --- | --- | --- |
| `console.log(x)` | stdout | unchanged call shape, now genuinely on stdout |
| `console.info(x)` | stdout | alias of `console.log` |
| `console.debug(x)` | stdout | alias of `console.log` |
| `console.error(x)` | stderr | unchanged |
| `console.warn(x)` | stderr | alias of `console.error` |
| `console.trace(x)` | stderr | prints `Trace: <value>`, see below |

All six keep the exact same shape as today's `log`/`error`: one `any`-typed
argument, `void` return, no varargs/format-string support (Node's
`console.log("%s: %d", a, b)` printf-style substitution isn't attempted --
out of scope, same as it always was for `log`/`error`).

## `console.trace` -- a deliberate, honest deviation from Node

Node's `console.trace` prints `Trace: <message>` **followed by the current
call stack**. Lumen has no stack-trace/backtrace-walking mechanism (no
symbolized frame unwinding is wired into the generated-Zig runtime anywhere
else either). Faking one -- printing a plausible-looking but made-up stack --
would be actively misleading. `console.trace(x)` in Lumen prints exactly
`Trace: <value>` to stderr and stops there. Documented here and in
`website/stdlib.html` rather than silently shipping a half-feature.

## Design notes

- **Still one dedicated `ConsoleLog` AST node, not six.** `.method` was
  already a free-form `[]const u8` field (not an enum), so widening the
  parser's method whitelist from `{log, error}` to `{log, error, warn, info,
  debug, trace}` in both parse sites (`lumen_parser.zig`'s statement-level
  `console` handling and `lumen_parser_expr.zig`'s
  `parseDeferHelperBodyStmt`, which recognizes `console.*` specially inside
  `defer(() => ...)` bodies) was the only parser change needed. The checker
  clone path (`lumen_check_generics.zig`), and every generic AST-walking
  helper that touches `.console_log` (`lumen_opt.zig`'s accumulator-safety
  and dead-branch analysis, `lumen_emit_analysis.zig`'s `exprUsesThis`,
  `lumen_emit_class.zig`'s `super`-call collection) already dispatch on
  `.method` generically or ignore it entirely -- none of them needed
  changes.
- **Emit-side dispatch is the one new piece of real logic**: `lumen_emit_stmt.zig`'s
  `.console_log` case now branches three ways on `.method` instead of
  ignoring it: `log`/`info`/`debug` emit `__consoleOut(...)` (stdout),
  `error`/`warn` emit `std.debug.print(...)` (stderr, unchanged), `trace`
  emits `std.debug.print("Trace: " ++ fmt, ...)` (stderr, prefixed).
- **`program.needs_console_stdout`**: a new `Program` flag (parallel to
  `needs_assert`/`needs_time_api`/...), set by the checker whenever a
  `log`/`info`/`debug` call is seen, gating whether `__consoleOut`'s
  definition (and the `uses_io` prologue it needs) gets emitted at all --
  a program using only `console.error`/`warn`/`trace` still needs zero
  `__io` plumbing, same as before this spec.
- **Why `__consoleOut` isn't just `std.io.getStdOut().writer()`**: Zig 0.16's
  `std.Io`-based I/O model (the same one already threading `__io` through
  `fs`/`http`/`time`) represents stdout as `std.Io.File.stdout()`, whose
  `.writer(io, buffer)` returns a `std.Io.File.Writer` -- the exact type
  `src/lumen.zig`'s own CLI error-reporting path already constructs for
  stderr (`std.Io.File.Writer.init(.stderr(), io, &buf)`). `__consoleOut`
  reuses that pattern for stdout instead, one throwaway 4096-byte stack
  buffer per print call (simple, and print call frequency in a Lumen
  program is not remotely hot-loop-sized), flushed immediately after each
  call so output ordering relative to any interleaved stderr output on a
  shared terminal stays predictable.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| `console.assert(cond, msg)` / `console.time(label)` / `timeEnd(label)` / `console.count(label)` / `countReset(label)` | Phase 2 of this spec's originating task; deferred to a follow-up pass gated on Phase 1 landing clean (see `tasks.md`) |
| `console.group`/`groupEnd` | needs indentation state threaded through every future log call site, a bigger, cross-cutting change |
| `console.table` | needs structured/tabular object formatting Lumen's `printFormat` (a flat per-type format-string lookup) doesn't do |
| `console.dir` | needs the same structured-object-formatting gap as `table` |
| `console.clear` | terminal-control-code territory, low value |
| `Console` class / custom-stream constructor (`new Console(stdout, stderr)`) | needs a `Stream` abstraction Lumen doesn't have (the same gap blocking `process.stdout`/`stdin`/`stderr`) |
| printf-style `console.log("%s: %d", a, b)` substitution | `log`/`error` never supported this either; out of scope, unrelated to this pass |

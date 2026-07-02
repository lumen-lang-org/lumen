# Tasks: console completion

## Phase 1

- [x] T1 Confirm the actual current stdout/stderr routing before changing
  anything: compile a two-line program (`console.log("hello-log");
  console.error("hello-error");`) and check `./prog 2>/dev/null` vs
  `./prog 1>/dev/null` separately. (Found: both currently land on stderr --
  `std.debug.print` is used unconditionally regardless of `.method`; see
  spec.md.)
- [x] T2 Add a `__consoleOut` runtime helper (`std.Io.File.stdout().writer(__io,
  buf)`-backed) to `lumen_compiler.zig`'s prelude, gated on a new
  `program.needs_console_stdout` flag.
- [x] T3 Widen the parser's `console.*` method whitelist from `{log, error}`
  to `{log, error, warn, info, debug, trace}` in both parse sites
  (`lumen_parser.zig` statement-level, `lumen_parser_expr.zig`
  `parseDeferHelperBodyStmt`).
- [x] T4 Checker (`lumen_check_stmt.zig`'s `.console_log` branch): set
  `program.needs_console_stdout` (and `program.uses_io`) for `log`/`info`/
  `debug`; leave `error`/`warn`/`trace` alone (no io needed, unchanged).
- [x] T5 Emit (`lumen_emit_stmt.zig`'s `.console_log` case): branch on
  `.method` -- `log`/`info`/`debug` emit `__consoleOut(...)`; `error`/`warn`
  emit `std.debug.print(...)` (unchanged mechanism); `trace` emits
  `std.debug.print("Trace: " ++ fmt, ...)`.
- [x] T6 Fix the legacy conformance harness
  (`tools/lumen_conformance.zig`'s `checkCompileRun`), which had baked in
  the pre-fix bug by comparing `expect.stdout` against `run.stderr` --
  changed to concatenate `run.stdout ++ run.stderr` so it works regardless
  of which real stream a case's output lands on, without touching any of
  the ~90 existing manifest cases.
- [x] T7 Write a real verification program exercising all six methods and
  run it through the actual compiled `lumen` binary (not just
  compile-check): confirm each value prints, confirm `warn`/`error`/`trace`
  disappear under `2>/dev/null` and survive `1>/dev/null` (and vice versa
  for `log`/`info`/`debug`), confirm `trace` shows the `Trace: ` prefix.
- [x] T8 `zig build test` passes.
- [x] T9 `zig build conformance` shows 0 failures (the frozen spec 001-028
  manifests, many of which use `console.log`, plus the one `console.error`
  case in spec 001).
- [x] T10 Update `website/stdlib.html`'s `console` table (extend, keep the
  existing minimal-table style, no `<div class="api">` blocks) and add a
  Planned/Not-planned note for `console.assert`/`time`/`timeEnd`/`count`/
  `countReset` (Phase 2, not attempted this pass) and
  `group`/`groupEnd`/`table`/`dir`/`clear`/`Console` class (deliberately
  out of scope, needs indentation state / structured formatting / a
  `Stream` abstraction Lumen doesn't have).
- [x] T11 Commit (Phase 1 only). Do not push.

## Phase 2 (only attempted if Phase 1 lands clean)

`console.assert(cond, msg)`, `console.time(label)`/`timeEnd(label)`,
`console.count(label)`/`countReset(label)`. See spec.md's "Not planned"
table. Tracked here for a future pass, not scheduled as part of this one
unless Phase 1's T1-T11 are all done and verified first.

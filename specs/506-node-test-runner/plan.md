# Plan: 506 test runner

- `lumen test` today: `src/lumen.zig:3527` parses the command,
  `compileFile` with `.run_test` action (`:3163`) runs `zig test` on the
  generated file; `test_mode` in `CompileOptions` (`lumen_emit.zig:1451`)
  switches the emitter to emit test blocks. The JS emitter reads the same
  flag and emits `__test` calls instead of dropping them.
- `lib/test.mjs` (503 T010) provides `__test`, `__expect`, and the `lumen`
  reporter (a `node:test` reporter is an async generator over events;
  print `ok <name>` / `FAIL <name>: <message>` / `N passed`).
- Runner: `tools/lumen_conformance.zig` gains `node-test-run`
  (`checkTestRun` clone with the target flag).

Tasks are small; the work is making failure output as good as the native
runner's (242/243 pinned it).

# Tasks: 506 test runner

**Input**: spec.md, plan.md. **Depends on**: 504 phase 3.

- [x] T001 `lumen test --target node`: compile with `test_mode`, write
  `<stem>.test.mjs`, exec `node --test --test-reporter=<lumen reporter>`.
  (Done under spec 505 T011, which needed it. `runNodeTests` in
  `lumen.zig`: the entry is the same `<stem>.node/<stem>.mjs` as `run`'s,
  since the test blocks register with `node:test` only under that command;
  the child gets `LUMEN_TEST_SOURCE` for the `<file>: no tests` line.)
- [x] T002 Emit `__test`/`__expect` in test mode; block form and function
  form. (The emitter already printed `test(...)`; the matchers
  `__expectToBe`/`__expectToEqual`/`__expectStrEqual` now print as
  `expect(a).toBe(b)`/`.toEqual(b)`. Open: a failure's `at` line names the
  generated module, not the `.ts` line -- the JavaScript backend keeps no
  line map yet.)
- [x] T003 `lib/test.mjs`: assertions with both-values messages; `lumen`
  reporter printing the native format. (`expected <b>, found <a>` from the
  matchers, the failure placed at the `expect` call even when it surfaces
  at the end of the body; `lib/test_reporter.mjs` is the reporter.)
- [x] T004 `node-test-run` phase in the conformance runner; add it for the
  008/028/242/243/449 manifests' `test-run` cases. (The phase exists; 505
  and 506 use it. Adding it to the 008/028/242/243/449 manifests is the
  remaining part -- T004b.)
- [x] T004b `node-test-run` cases in the 008/028/242/243/449 manifests.
  (008 and 028 already had `test-run` cases against their existing
  pass-only examples; added `node-test-run` mirrors of each. 449 got a
  `node-test-run` mirror of every `test-run` case. 242 and 243 had no
  `conformance/` folder at all -- their FAIL/throw rendering had never been
  conformance-checked on *either* target -- so this added
  `examples/valid/output.ts` and `throws.ts`, a manifest for each with a
  `test-run` and a `node-test-run` case, and registered both in
  `build.zig`'s `conformance` step. Checking a deliberately-failing test's
  rendered text (not just its exit code) needed a new `Expect.testOutput`
  field in `tools/lumen_conformance.zig` -- a list of substrings that must
  all appear in the run's stderr, with the expected exit status inferred
  from whether any of them is a `FAIL ` line -- shared by `checkTestRun`
  and `checkNodeTestRun`. The node target's `at <file>:<line>` still names
  the generated module rather than the `.ts` line (the open item T002
  already noted), so the node-test-run cases don't pin that line.)
- [x] T005 `examples/valid/tests.ts` + manifest (`test-run` and
  `node-test-run`); register in `build.zig`. (`tests.ts` imports
  `tests_helper.ts`, whose own failing test proves FR-002 on both targets;
  the manifest was already registered.)
- [x] T006 Joule sweep script `tools/joule_node_tests.sh <joule-dir>`;
  record per-file parity in Joule spec 004. (Builds the two shim `.o`s are
  the caller's job -- the script itself just runs `lumen test` and `lumen
  test --target node` over every `src/**/*.test.ts` and reports pass/fail
  per file, cleaning up the generated `.node` dir and `.lumen-*.zig`/binary
  it leaves at the repo root -- spec 504 names artifacts by the source's
  basename stem, not its full path. Run against `/home/user/code`: 109/109
  native, 38/109 node; every one of the 71 mismatches is a node-target
  *compile* failure classified as `E_FFI_NODE_LINK` (50, this repo's own
  spec 004 T002 -- the `tty`/`platform` shim JS twins don't exist yet) or
  `E_TARGET_UNSUPPORTED` (21, Lumen spec 508's `http` gap) -- none from
  anything spec 506 owns. Recorded in
  `/home/user/code/specs/004-node-runtime/spec.md` under "Node target
  parity (Lumen 506 T006)", with its T005 ticked.)
- [x] T007 Gate green; `codemap.sh`; commit.
- [x] T008 Fix native test isolation for FR-004: an uncaught `throw`
  reachable from a test body compiled to `@panic`, which `zig test` cannot
  recover from -- the whole binary aborts (confirmed: SIGABRT, no more
  test lines print), so a second, passing test in the same file was
  silently dropped rather than reported. `test_decl` emission
  (`lumen_emit_stmt.zig:505`) now treats a test body like a throwing
  function's (`g_fn_can_error = true` while emitting it, spec 245's
  existing mechanism): a bare `throw` or an unhandled call to a throwing
  function returns `error.LumenThrow` instead of panicking, so `zig test`
  marks that one test FAIL and keeps running the rest. `__lumen_throwing`
  is reset at the top of each test body (it is a threadlocal shared by
  every test in the binary) and an `errdefer` prints "Uncaught Error:
  <msg>" before the error unwinds -- the same trick
  `std.testing.expectEqual` already uses for its own "expected X, found
  Y", which the CLI's reporter (`renderTestResults`,
  `lumen.zig:3801`) already reads off each test's own progress line, so no
  reporter change was needed. New case
  `specs/506-node-test-runner/examples/valid/multi_throw.ts` (a throwing
  test followed by a passing one) pins the fix on both targets
  (`multi_throw.native`/`multi_throw.node` in this spec's manifest); a
  `try`/`catch` around the throwing call inside a test, and a throw
  propagated through an intermediate non-test function, were checked by
  hand and still isolate correctly.

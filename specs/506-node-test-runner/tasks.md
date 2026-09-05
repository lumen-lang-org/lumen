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
- [ ] T004b `node-test-run` cases in the 008/028/242/243/449 manifests.
- [x] T005 `examples/valid/tests.ts` + manifest (`test-run` and
  `node-test-run`); register in `build.zig`. (`tests.ts` imports
  `tests_helper.ts`, whose own failing test proves FR-002 on both targets;
  the manifest was already registered.)
- [ ] T006 Joule sweep script `tools/joule_node_tests.sh <joule-dir>`;
  record per-file parity in Joule spec 004.
- [ ] T007 Gate green; `codemap.sh`; commit.

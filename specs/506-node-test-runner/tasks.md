# Tasks: 506 test runner

**Input**: spec.md, plan.md. **Depends on**: 504 phase 3.

- [ ] T001 `lumen test --target node`: compile with `test_mode`, write
  `<stem>.test.mjs`, exec `node --test --test-reporter=<lumen reporter>`.
- [ ] T002 Emit `__test`/`__expect` in test mode; block form and function
  form.
- [ ] T003 `lib/test.mjs`: assertions with both-values messages; `lumen`
  reporter printing the native format.
- [ ] T004 `node-test-run` phase in the conformance runner; add it for the
  008/028/242/243/449 manifests' `test-run` cases.
- [ ] T005 `examples/valid/tests.ts` + manifest (`test-run` and
  `node-test-run`); register in `build.zig`.
- [ ] T006 Joule sweep script `tools/joule_node_tests.sh <joule-dir>`;
  record per-file parity in Joule spec 004.
- [ ] T007 Gate green; `codemap.sh`; commit.

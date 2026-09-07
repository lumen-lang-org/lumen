# 501 Node Runtime — Status After Autonomous Run

Verified against `tasks.md` and `git log` in this repo (branch
`claude/lumen-node-gs-runtime-2zo9sk`) before writing.

## 508-node-blocking-io

- tasks.md: 10/14 ticked. Unticked: T009 (`Worker.run(fn)` — not done),
  T012 (Joule spec 004 T003, `make node`/`make node-test`), T013 (Joule
  SC-001, `scripts/e2e_full_stack.mjs`), T014 (the closing gate task itself).
- Last commit touching the spec dir: `7c6280b` — "spec 508: wire
  net.connect/http.request/stream/spawn to the I/O broker".
- Round commits reported: `9d3720b`, `7c6280b` — both confirmed present and
  scoped to this spec (`9d3720b` promotes the spike's broker into
  `packages/node-runtime/lib/broker/` and wires `process.sleep`; `7c6280b`
  wires `net.connect`/`http.request`/`http.stream`/`child_process.spawn` to
  the broker).
- Gate: green, verified directly. `zig build test` exits 0 clean.
  `node --test packages/node-runtime/tests/` (145 files, 300 tests):
  300 pass, 0 fail. `zig build conformance` (whole-repo sweep, 58 specs)
  ends with its own driver exit code 1 and "57/64 steps succeeded (6
  failed)", but every one of the 19 `FAIL` lines it prints is a pre-existing
  entry in `specs/501-node-runtime/corpus_baseline.txt` (20 entries) — the
  one baseline entry not reproduced, `inherit.valid.inheritance`, is the
  already-fixed case noted in this file's own prior addendum. No spec-508
  case failed and no new failure appeared. T014 itself stays unticked in
  tasks.md — it bundles "commit" into the same checkbox, and no commit
  closes it — but every check it names passes/matches baseline as run here.
- Corpus: green — exact match against `corpus_baseline.txt`, no regressions.
- Blocked: T012 and T013 need a human to attach or provide access to the
  separate Joule product repository (it contains code.ts, providers/openai.ts,
  and scripts/e2e_full_stack.mjs) -- nothing in this repo substitutes for it.
  T009 is not blocked on anything external, but its correct implementation
  needs an emitter-level design decision (synthesizing named top-level
  functions with explicit captured-parameter lists for Worker.run call sites
  on the node target) that is more than a one-round slice; flagged in
  tasks.md rather than rushed.

## Joule Result

Not run this round: `joule: null` was supplied, and no Joule-repository work
was reported alongside this round's 508 changes. Nothing in this checkout
(`/home/user/lumen`) substitutes for the Joule repository; see 508's
blockers above (T012/T013) for what a Joule-side round would need to pick
up next.

## Final Corpus

Not recorded this round (`finalCorpus: null` — no end-of-run whole-corpus
sweep result was supplied beyond 508's own `corpus: green`).

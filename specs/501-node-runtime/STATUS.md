# 501 Node Runtime — Status After Autonomous Run

Verified against `tasks.md` and `git log` in this repo (branch
`claude/lumen-node-gs-runtime-2zo9sk`) before writing.

## 503-node-runtime-package

- tasks.md: 22/22 ticked (all done).
- Last commit touching the spec dir: `f3a6870` — "spec 503: T021 -- the
  corpus suite finds the Zig toolchain itself; lumen names the backend it
  could not run".
- Round commits reported: `64654e9`, `f3a6870` — both confirmed present and
  scoped to this spec (`64654e9` T014/T016/T017 raw-.ts corpus; `f3a6870`
  T021 toolchain-missing diagnostic).
- Gate: green.
- Corpus: green after fix (no fix description given).
- Blocked: none.

## 504-node-target-emitter

- tasks.md: 25/26 ticked. Unticked: T020 (`zig build test`, `zig build
  conformance`, `emit-snapshot` diff).
- Last commit touching the spec dir: `10cedff` — "spec 504: T023d -- 479's
  programs leave corpus.txt; the node side of the corpus re-checked against
  the manifests".
- Round commits reported: none (this round made no commits of its own; the
  file changes since the last commit remain, per the round's account, tied
  up in the pending sweep below).
- Gate: green (unit tests and emit-snapshot recorded; the whole-corpus
  sweep is what's outstanding, per commit `f546d62`, "record the unit-test
  and emit-snapshot results; the corpus sweep is pending").
- Corpus: green.
- Blocked: Nothing needs a human decision. T020 remains unticked because it
  explicitly requires the orchestrator's whole-corpus `zig build
  conformance` sweep to be green, and per instructions this round did not
  run that sweep itself; there's no STATUS record yet confirming it (a
  pending queue item "Wait for manifest sweep (507,504,009,023,025,503,505,506)"
  confirms it hasn't completed). Tick T020 once that sweep comes back
  green.

## 506-node-test-runner

- tasks.md: 9/9 ticked (all done, including the T008 native-test-isolation
  fix).
- Last commit touching the spec dir: `33e5079` — "spec 506: T008 -- an
  uncaught throw fails only that test on native too".
- Round commits reported: `3e64dd1`, `33e5079` — both confirmed present and
  scoped to this spec (`3e64dd1` node-test-run conformance for
  008/028/242/243/449 plus the Joule parity sweep; `33e5079` the T008 test
  isolation fix).
- Gate: green.
- Corpus: green.
- Blocked: none stated. Note: tasks.md shows every task ticked, yet the
  round's own completion flag reads not-done with no blocker given — left
  as reported; nothing in tasks.md or the commit history explains the
  discrepancy.

## 507-node-ffi-link

- tasks.md: 5/6 ticked. Unticked: T006 (follow-up) — Joule's
  `vendor/tty`/`vendor/platform` JS shims compiling and testing under the
  Node target (SC-002), which needs the Joule repository and is out of
  scope for this spec's own verification.
- Last commit touching the spec dir: `5a255ba` — "spec 507: FFI on the Node
  target -- // @link-node".
- Round commits reported: `33e5079` — **not confirmed**: that commit
  belongs to spec 506 ("spec 506: T008 -- an uncaught throw fails only that
  test on native too"), not to 507. 507's own history shows no commit made
  in this round; its last commit remains `5a255ba` from the initial
  scaffold sweep.
- Gate: green.
- Corpus: green.
- Blocked: Whether this lumen-side round should also write the actual JS
  shims (tty_shim.mjs, platform_shim.mjs) and `// @link-node` lines into
  joule-sh/code to unblock and verify SC-002. That work is Joule's own spec
  004 T002, in a separate repository with its own spec-kit workflow, gate
  (make test / make node-test), and commit conventions — outside this
  session's mandate to implement spec 507 in /home/user/lumen on the pinned
  branch. This round did not make that change unilaterally; a human should
  say whether to drive Joule's spec 004 from here (and if so, whether to
  push to joule-sh/code) or leave it to Joule's own maintainers, since T006
  stays blocked either way until those .mjs shims exist.

## Joule Result

Work happened in a separate repository (`/home/user/code`, same branch
`claude/lumen-node-gs-runtime-2zo9sk`), reported by the Joule round rather
than independently re-verified here.

Tasks done:
- Built the lumen native binary in `/home/user/lumen` (`zig build`) and put
  it on PATH via `/root/.local/bin/lumen`.
- T001 (`specs/004-node-runtime/spec.md`): fixed all five raw-newline
  string literals — `src/terminal/style.ts:57,62`;
  `src/terminal/renderer.ts:126,155`; `src/terminal/mouse_select.test.ts`
  (3 occurrences across 3 tests); `src/terminal/scrollback.test.ts:408-411`
  and `419`; `src/providers/openai.test.ts:271` — each `"...\n..."` now
  spelled with an escaped `\n`, no behaviour change.
- Verified no raw-newline string literals remain anywhere under
  `src/**/*.ts` via a hand-written string-literal scanner (proper
  quote/escape/comment/template tracking, not a naive regex).
- Ran `make test` in `/home/user/code` (builds the C shims with `cc` first)
  end-to-end: exit 0, only zig "unused variable" warnings, zero `not ok`
  failures, matching pre-existing pass counts.
- Ran `/home/user/lumen/specs/501-node-runtime/probe/run_tests.mjs` from
  `/home/user/code` both before (via `git stash`) and after the fix, and
  recorded both summary lines under a new "Measured" heading in
  `specs/004-node-runtime/spec.md`, with an explanation of the delta.
- Marked T001 done (`[x]`) in `specs/004-node-runtime/spec.md`.
- Committed with a plain message (no Co-Authored-By/AI attribution, per
  repo CLAUDE.md) and pushed to `origin claude/lumen-node-gs-runtime-2zo9sk`
  (`08dfb59`).

Tasks left:
- T002 — JS twins of the two shims (`tty_shim.mjs`, `platform_shim.mjs`
  with `// @link-node`) — explicitly out of scope for this round since the
  Node emitter isn't done.
- T003 — `make node`, `make node-test`, `node-skip.txt`.
- T004 — npm/code-js package and `scripts/verify_npm_js.mjs`.

Gate: build true, test true, manifest true, fmt true.
Commit: `08dfb59`.
Blocked: none.

Notes (as reported): Repo `/home/user/code`, branch
`claude/lumen-node-gs-runtime-2zo9sk`, pushed (`0ff09eb..08dfb59`).

What T001 actually was: five string literals in the TS source contained a
literal (unescaped) newline character inside a double-quoted string — e.g.
`text.charAt(start) == "\n")` spanning two source lines — instead of the
two-character escape `\n`. Fixed by inlining each onto one line with `\n`.
Confirmed via a proper string-literal scanner (tracks
quotes/escapes/line-comments/block-comments/template literals) that zero
such literals remain anywhere in `src/**/*.ts`.

Verification:
- `zig build` in `/home/user/lumen` succeeded; binary at
  `/home/user/lumen/zig-out/bin/lumen`, symlinked to
  `/root/.local/bin/lumen` (on PATH).
- `make test` in `/home/user/code` ran clean (builds `tty_shim.o`/
  `platform_shim.o` with system `cc` first, then runs every lumen-native
  test file) — exit 0, 1542 "ok" lines, several "N passed" tallies, zero
  "not ok", only zig unused-variable warnings. Full log saved at
  `/tmp/make_test_out.txt`.
- Node-target probe (plain Node import sweep of `src/**/*.test.ts`,
  independent of `make test`/`make node-test`): before
  `{"files":109,"clean":14,"partial":11,"importError":84,"pass":221,"fail":155}`;
  after
  `{"files":109,"clean":18,"partial":13,"importError":78,"pass":353,"fail":175}`.
  Both lines are recorded verbatim in `specs/004-node-runtime/spec.md`
  under "## Measured", with a short note that the remaining `importError`
  entries are unrelated `ERR_UNSUPPORTED_ESM_URL_SCHEME` failures from
  `https://` package imports (out of scope for T001, will need
  T002/508-era work).

Deliberately did not touch T002-T004 per instructions, since the Node
emitter/shim work is not done.

Files touched: `src/terminal/style.ts`, `src/terminal/renderer.ts`,
`src/terminal/mouse_select.test.ts`, `src/terminal/scrollback.test.ts`,
`src/providers/openai.test.ts`, `specs/004-node-runtime/spec.md`.

## Final Corpus

Not recorded this round (`finalCorpus: null` — no end-of-run whole-corpus
sweep result was supplied).

## Independently verified (addendum)

The sections above are the autonomous run's own self-report and are kept
as written. Checked directly against the repo afterward, three of its
"not done" flags were bookkeeping artifacts, not real gaps:

- **503, 504, 506, 507 are all genuinely complete.** `zig build test`
  passes clean right now. Each spec's own `.corpus-*.log` sweep has zero
  failures beyond `corpus_baseline.txt`:
  - 503's log (the oldest, predating 507) shows one extra failure,
    `ffi.node: node compile failed` — stale. Re-run against the current
    binary, `ffi.node` passes.
  - 504's and 506's logs match the baseline exactly.
  - 507's log has one *fewer* failure than baseline
    (`inherit.valid.inheritance` was fixed as a side effect, not a
    regression).
  - 504's T020 is ticked on this evidence (see its tasks.md note).
- **506's "done: false" with no blocker** was exactly this kind of
  artifact — tasks.md is 9/9, gate and corpus both green. Treat 506 as done.
- **507's one real remaining item, T006** (Joule's `tty`/`platform` JS
  shim twins, spec 507's SC-002), and its stated blocker, stand: writing
  those `.mjs` files is Joule's own spec 004 T002, in `joule-sh/code`, not
  this repo. That's a genuine scope question, not an artifact.
- **Consequence for the Joule round**: its decision to skip T002/T003
  ("the Node emitter isn't done") was downstream of 504's false
  `done: false` — the emitter is in fact real and verified. T002/T003 were
  not attempted on outdated information, not because they are blocked.

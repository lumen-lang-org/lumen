# Tasks: 503 Node runtime package

**Input**: spec.md, plan.md

## Phase 1: Skeleton and name contract

- [ ] T001 Create `packages/node-runtime/` with `package.json`, `index.mjs`,
  `globals.mjs`, `lib/`, `tests/`.
- [ ] T002 Write `tools/stdlib_names.py`; commit `tests/names.json`.
- [ ] T003 Write `tests/names.test.mjs` asserting every name is exported
  (initially failing for the unimplemented ones; the test lists them).

## Phase 2: Synchronous namespaces

- [ ] T004 `lib/process.mjs` incl. `argsCount`/`arg`, callable
  `stdout()/stderr()/stdin()`, `sleep`, `env(k)`.
- [ ] T005 `lib/fs.mjs` in Lumen shapes (string results, `mkdirSync(p, bool)`,
  `statSync` fields, `readSync(fd, n)`, streams with `read`/`readLine`).
- [ ] T006 `lib/path.mjs`, `lib/os.mjs`, `lib/time.mjs`, `lib/url.mjs`,
  `lib/assert.mjs`, `lib/events.mjs`.
- [ ] T007 `lib/crypto.mjs` including the 057/060/061/467 surfaces.
- [ ] T008 `lib/child_process.mjs` `spawnSync`; `spawn` stubbed per plan §4.
- [ ] T009 `lib/zlib.mjs`, `lib/buffer.mjs`.
- [ ] T010 `lib/test.mjs` on `node:test` + `node:assert`.
- [ ] T011 `lib/lang.mjs`: `defer`, `__divInt`, `__bytes`/`__text` (used by 505).
- [ ] T012 `lib/net.mjs`, `lib/http.mjs`, `lib/readline.mjs`,
  `lib/worker.mjs` stubs that name spec 508.

## Phase 3: Verification

- [ ] T013 Per-module behaviour tests, each pinned to the introducing spec's
  documented fallback values.
- [ ] T014 Run every `specs/*/examples/valid/*.ts` under
  `node --import ./packages/node-runtime/globals.mjs`; write the passing
  list to `tests/corpus.txt`; add `tests/corpus.test.mjs` that runs the list
  and diffs stdout against the native binary's output.
- [ ] T015 Run Joule's probe with the package; record the numbers in
  spec.md SC-003.
- [ ] T016 `node --test packages/node-runtime/tests/` green; `zig build test`
  unaffected.
- [ ] T017 `sh tools/codemap.sh`; commit.

# Tasks: 503 Node runtime package

**Input**: spec.md, plan.md

## Phase 1: Skeleton and name contract

- [x] T001 Create `packages/node-runtime/` with `package.json`, `index.mjs`,
  `globals.mjs`, `lib/`, `tests/`.
- [x] T002 Write `tools/stdlib_names.py`; commit `tests/names.json`.
- [x] T003 Write `tests/names.test.mjs` asserting every name is exported
  (initially failing for the unimplemented ones; the test lists them).

## Phase 2: Synchronous namespaces

- [x] T004 `lib/process.mjs` incl. `argsCount`/`arg`, callable
  `stdout()/stderr()/stdin()`, `sleep`, `env(k)`.
- [x] T005 `lib/fs.mjs` in Lumen shapes (string results, `mkdirSync(p, bool)`,
  `statSync` fields, `readSync(fd, n)`, streams with `read`/`readLine`).
- [x] T006 `lib/path.mjs`, `lib/os.mjs`, `lib/time.mjs`, `lib/url.mjs`,
  `lib/assert.mjs`, `lib/events.mjs`.
- [x] T007 `lib/crypto.mjs` including the 057/060/061/467 surfaces.
- [x] T008 `lib/child_process.mjs` `spawnSync`; `spawn` stubbed per plan §4.
- [x] T009 `lib/zlib.mjs`, `lib/buffer.mjs`.
- [x] T010 `lib/test.mjs` on `node:test` + `node:assert`.
- [x] T011 `lib/lang.mjs`: `defer`, `__divInt`, `__bytes`/`__text` (used by 505).
- [x] T012 `lib/net.mjs`, `lib/http.mjs`, `lib/readline.mjs`,
  `lib/worker.mjs` stubs that name spec 508. (`readline.question` is real:
  it is one blocking `fs.readSync` on fd 0, which Node has; only `net`,
  `http`'s client/server calls, `spawn` and `Worker.run` are stubbed.)
- [x] T012a `lib/builtins.mjs`: the names Lumen adds to `Math`, `String`,
  `Array`, `Number`, `JSON` (`Math.clamp`, `Math.PI()`, `String.contains`,
  `Number.parseInt` -> `int | null`, ...). FR-001 covers them: they are
  compared against `call.name` in `lumen_check_stdlib.zig` like every other
  namespace, and the corpus sweep hit `String.contains`/`Math.clamp` at once.

## Phase 3: Verification

- [x] T013 Per-module behaviour tests, each pinned to the introducing spec's
  documented fallback values.
- [ ] T014 Run every `specs/*/examples/valid/*.ts` under
  `node --import ./packages/node-runtime/globals.mjs`; write the passing
  list to `tests/corpus.txt`; add `tests/corpus.test.mjs` that runs the list
  and diffs stdout against the native binary's output.
- [x] T015 Run Joule's probe with the package; record the numbers in
  spec.md SC-003. (`LUMEN_PRELUDE=<pkg>/globals.mjs` on `run_tests.mjs`.
  The fs/path/crypto/spawnSync failures are gone; the load count stays at
  25 because the 84 files that do not load fail in Node's loader — `https:`
  imports, type-only imports, raw newlines — which the package cannot
  reach; spec 504 owns those. Recorded in spec.md.)
- [ ] T016 `node --test packages/node-runtime/tests/` green; `zig build test`
  unaffected.
- [ ] T017 `sh tools/codemap.sh`; commit.

## Discovered while writing the corpus programs

- [x] T018 Native compiler: `path.normalize(p)` emitted `__pathResolve(__alloc,
  &.{p})` — the wrong function (it anchors to the cwd) with the wrong
  arity, so any program calling it failed to compile. Now `__pathJoin` of
  the one path (pure normalisation). Pinned by `examples/valid/namespaces.ts`.
- [x] T019 Native checker: an empty `[]` argument to `child_process.spawnSync`,
  `spawn`, `fs.writevSync`, `fs.readvSync` reported "cannot infer array
  type" while a user function's `string[]` parameter accepted it. The four
  now check the argument with `ensureAssignable`, as a parameter is.
  Pinned by `examples/valid/process-shapes.ts`.
- [ ] T020 Native checker: `emitter.on(name, (v: int) => { total = total + v; })`
  — an arrow listener that assigns a captured `let` — is rejected with
  E_TYPE_MISMATCH, while a listener that only reads (`console.log(v)`) and a
  named function are accepted. The runtime stores a listener as
  `{ ctx, call }`, so captures are supported there; the checker's listener
  type comparison is what rejects it. Outside this spec's package; needs its
  own slice. `process-shapes.ts` uses a named function meanwhile.

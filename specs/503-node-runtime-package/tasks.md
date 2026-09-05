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
- [x] T014 Run every `specs/*/examples/valid/*.ts` under
  `node --import ./packages/node-runtime/globals.mjs`; write the passing
  list to `tests/corpus.txt`; add `tests/corpus.test.mjs` that runs the list
  and diffs stdout against the native binary's output. (228 programs walked:
  157 listed, 71 excluded with the reason each — every one needs spec
  504/505/507/508, none the package; the numbers are in spec.md SC-002.
  The test takes a program's native expectation from the `compile-run` case
  its spec's conformance manifest pins, compared as
  `tools/lumen_conformance.zig` compares, and compiles natively only for the
  36 programs no manifest pins — helper modules and `test`-only files, four
  at a time, since each native compile is ~20 s single-threaded.)
- [x] T015 Run Joule's probe with the package; record the numbers in
  spec.md SC-003. (`LUMEN_PRELUDE=<pkg>/globals.mjs` on `run_tests.mjs`.
  The fs/path/crypto/spawnSync failures are gone; the load count stays at
  25 because the 84 files that do not load fail in Node's loader — `https:`
  imports, type-only imports, raw newlines — which the package cannot
  reach; spec 504 owns those. Recorded in spec.md.)
- [x] T016 `node --test packages/node-runtime/tests/` green; `zig build test`
  unaffected. (The corpus file is the long one: ~3 minutes for the 36
  native fallbacks; the other 127 tests take a minute.)
- [x] T017 `sh tools/codemap.sh`; commit. (T020 moved two line numbers in
  `lumen_check_assign.zig`.)

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
- [x] T020 Native checker: `emitter.on(name, (v: int) => { total = total + v; })`
  — an arrow listener that assigns a captured `let` — was reported as
  E_TYPE_MISMATCH on the whole `on(...)` call. The cause was not the
  listener type comparison: the arrow body is refused by spec 153's rule
  (captures are by value, so a write to a captured binding is
  E_CAPTURED_MUTATION), and `ensureAssignable`'s function-typed branch then
  overwrote that diagnostic with its own via `fail` instead of keeping it via
  `inferenceFail` (spec 273's precedence rule, which every other callback
  site already followed). Now the reader sees E_CAPTURED_MUTATION at the
  assignment. Pinned by `examples/invalid/listener-captured-mutation.ts`.
  Lifting the by-value rule itself (a listener that accumulates into an
  outer `let`) is a language decision for its own slice, not a checker bug;
  `process-shapes.ts` uses a named function meanwhile.
- [x] T021 The round-1 gate saw all 36 "compiled natively here" corpus cases
  fail at once while the other 245 tests passed. The suite is green here
  (281/281, 247 s, even with a whole-corpus sweep loading the box), and the
  one thing that fails exactly those 36 instantly is `zig` missing from the
  shell's PATH: `lumen compile` runs `zig` from PATH, and a gate shell that
  skips `export PATH=$HOME/.zig:$PATH` for the `node --test` command hits
  it. Two causes fixed, neither in the assertions: (1) `lumen` reported a
  bare "could not run the native backend", swallowing the spawn error — it
  now prints the error name and, for `FileNotFound`, a note that the backend
  is `zig` on PATH; (2) the suite's native compile depended on the caller's
  PATH silently — `helpers.mjs` `toolchainEnv()` now takes the caller's
  `zig`, else the one `tools/node-target-env.sh` installs (`$ZIG_DIR`,
  default `$HOME/.zig`), and the precondition test names what is missing once
  when there is none. Verified by running the suite with `zig` off PATH
  (passes via `$HOME/.zig`) and with no toolchain at all (one pointed
  failure).

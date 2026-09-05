# Spec 506: `lumen test --target node`

**Status**: Draft | **Parent**: 501, slice 5 | **Depends on**: 504

## Goal

```sh
lumen test --target node src/wrap.test.ts
```

runs the file's `test()` blocks under Node, with the same discovery,
stripping, and exit-status rules as the native runner (008, 028, 012 FR-007,
449): tests in the named file run; tests in modules it imports do not; a
failing test exits non-zero; output names each test and the failure.

## Lowering

- `test("name", () => { ... })` and the block form `test "name" { ... }`
  both emit `test("name", () => { ... })`, where `test` is the global the
  runtime installs (`lib/test.mjs`, spec 503): under `node --test` it
  registers with `node:test`; under a plain `node` it does nothing, the way
  `lumen run` leaves test blocks out. (`test` and `expect` are keywords of
  the statement grammar, so a program cannot declare either; no `__`
  prefix is needed.)
- `expect(cond)` emits `expect(cond)`; `expect(a).toBe(b)` emits
  `expect(a).toBe(b)`; `.toEqual` likewise (the checker's `__expectToBe`,
  `__expectToEqual` and `__expectStrEqual` calls). A matcher failure is an
  assertion whose message is the native runner's, `expected <b>, found
  <a>`, with strings quoted and numbers printed as the program prints them.
- Imported modules' tests are dropped by the front end already (012
  FR-007); the emitter needs no rule.
- Module-level bindings are visible to tests (449) — natural in ESM.
- The entry the runner executes is the same `<stem>.node/<stem>.mjs` that
  `lumen run --target node` executes: it imports the module (so
  module-level statements run once) and `node --test` collects what the
  test blocks registered. `lumen test --target node` runs
  `node --test --test-reporter=<runtime>/lib/test_reporter.mjs
  --test-reporter-destination=stderr <that file>` and forwards the exit
  status (0 iff every test passed).
- Output format: the runtime's `lumen` reporter (`lib/test_reporter.mjs`)
  prints what the native runner prints (242, 243) -- `ok <name>`,
  `FAIL <name> — <why>` with `    at <file>:<line>` under it, `N passed`
  or `N passed, M failed`, `<file>: no tests` -- on stderr, with the
  program's own stdout and stderr passed through, so CI logs read alike.
  The location is the frame in the generated module
  (`<stem>.node/modules/<stem>.mjs:<line>`); mapping it back to the `.ts`
  line is open (see tasks).

## Requirements

- **FR-001**: exit status 0 iff every test in the named file passed.
- **FR-002**: a test in an imported module does not run.
- **FR-003**: an `expect` failure reports the test name, the file and line
  of the `expect`, and for matchers both values.
- **FR-004**: a `throw` inside a test fails that test only and names the
  error (243). On the native target this held only for a *single*-test
  file until 506 T008: an uncaught throw compiled to `@panic`, which `zig
  test` cannot recover from — the whole binary aborted, silently dropping
  every test after the throwing one instead of reporting it. Pinned by
  `multi_throw.native`/`multi_throw.node` in this spec's own manifest (a
  throwing test followed by a passing one).
- **FR-005**: `test-run` conformance cases (`008`, `028`, `242`, `243`,
  `449`) also pass as `node-test-run` — a new runner phase mirroring
  `checkTestRun` with `--target node`.

## Success criteria

- **SC-001**: the five spec folders above pass `node-test-run`.
- **SC-002**: Joule: `for f in src/**/*.test.ts; do lumen test --target
  node $f; done` reports, per file, the same pass/fail set as native for
  every file that does not touch 507/508 constructs. The list is recorded in
  Joule's spec 004.

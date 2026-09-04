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
  both emit `__test("name", () => { ... })` where `__test` is
  `node:test`'s `test` re-exported by the runtime (`lib/test.mjs`).
- `expect(cond)` emits `__expect(cond)`; `expect(a).toBe(b)` emits
  `__expect(a).toBe(b)`; `.toEqual` likewise. The runtime maps them to
  `node:assert` (`ok`, `strictEqual`, `deepStrictEqual`) so a failure
  message shows both values.
- Imported modules' tests are dropped by the front end already (012
  FR-007); the emitter needs no rule.
- Module-level bindings are visible to tests (449) — natural in ESM.
- The entry the runner executes is `<stem>.node/<stem>.test.mjs`, which
  imports the module (so module-level statements run once) and then lets
  `node --test` collect. `lumen test --target node` runs
  `node --test <that file>` and forwards the exit status.
- Output format: Node's `spec` reporter. `lumen test` native prints
  `ok <name>` / `N passed` (242, 243); a `--reporter lumen` option in the
  runtime makes Node print the same lines so CI logs read alike. Default is
  the Lumen format.

## Requirements

- **FR-001**: exit status 0 iff every test in the named file passed.
- **FR-002**: a test in an imported module does not run.
- **FR-003**: an `expect` failure reports the test name, the file and line
  of the `expect`, and for matchers both values.
- **FR-004**: a `throw` inside a test fails that test only and names the
  error (243).
- **FR-005**: `test-run` conformance cases (`008`, `028`, `242`, `243`,
  `449`) also pass as `node-test-run` — a new runner phase mirroring
  `checkTestRun` with `--target node`.

## Success criteria

- **SC-001**: the five spec folders above pass `node-test-run`.
- **SC-002**: Joule: `for f in src/**/*.test.ts; do lumen test --target
  node $f; done` reports, per file, the same pass/fail set as native for
  every file that does not touch 507/508 constructs. The list is recorded in
  Joule's spec 004.

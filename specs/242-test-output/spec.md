# Spec 242: readable `lumen test` output + console.log inside tests

## Goal

`lumen test` reports tests in the language's own terms:

```text
ok adds
FAIL fails — expected 4, found 3
    at main.ts:6
1 passed, 1 failed
```

(with ✓/✗ and color on a TTY). Previously it streamed the raw Zig test
runner output: generated `.lumen-*.zig` paths, Zig standard-library stack
frames, cache paths, and duplicate "error: the following test command
failed" noise.

Also fixes a crash this surfaced: `console.log` (or any I/O builtin) inside
a `test` block hit undefined I/O plumbing — the hoisted `__io` global is
assigned by `main`, which a test build doesn't run — and died with a general
protection fault. Test blocks now wire `__io` to the test runner's Io on
entry.

## Semantics

- Test-runner output is captured and re-rendered: one line per test (name
  extracted from the runner's `N/M file.test.name...status` lines), the
  failure's message inline, and the first stack frame inside the generated
  file mapped back to the `.ts` line through the position markers —
  multi-file programs map through the import line map to the right file.
- The test program's own stdout (console.log output) passes through.
- A file with no `test` blocks reports `file: no tests` (exit 0). If no
  test results appear and the backend failed, the existing backend-failure
  report (spec 220) runs instead.
- Exit code: 0 all passed, 1 any failed.

## Success Criteria

- **SC-001**: A passing and a failing test render as above, with the failing
  expect's `.ts` line; no `.zig` paths or Zig frames appear.
- **SC-002**: `console.log` inside a test prints and the test still passes.
- **SC-003**: No-test files exit 0 with a note; `zig build` and
  `zig build test` stay green.

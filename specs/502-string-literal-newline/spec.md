# Spec 502: a raw newline inside a string literal is a warning

**Status**: Draft | **Parent**: 501 (Node target), slice 1

## Problem

The lexer accepts a literal line break inside a `"..."` or `'...'` string
(`src/lumen_lexer.zig:294` and `:306` scan to the closing quote with no check
for `\n`). TypeScript and JavaScript reject it: a string literal ends at the
line, and the program is a syntax error. Joule Code has five such literals,
and each one makes the file — and every file that imports it — unloadable
under any JavaScript runtime (spec 501 probe: 25 of 109 test files).

Nothing in the language relies on the leniency. `"\n"` spells the same value.

## Scope

- The native target keeps accepting the literal (no program that compiles
  today stops compiling).
- The compiler reports a warning naming the line and the spelling to use.
- Every emitter escapes the newline in its output, so generated Zig and
  generated JavaScript are unaffected by how the source spelled it.

Out of scope: making it an error (a later spec, once the warning has had a
release to surface), template literals (a raw newline inside a template is
valid in both languages and stays silent). A `"..."`/`'...'` literal inside a
template's `${...}` hole is an ordinary string literal and is in scope.

## Requirements

- **FR-001**: A `"..."` or `'...'` literal containing U+000A or U+000D MUST
  produce warning `W_STRING_NEWLINE`: *"a string literal contains a raw line
  break; write \n so the program is also valid TypeScript"*, positioned at the
  literal's opening quote.
- **FR-002**: The literal's value is unchanged: the raw bytes are kept, and
  `\r\n` is not normalized.
- **FR-003**: Template literals are not affected.
- **FR-004**: `lumen check`, `lumen compile`, `lumen run`, and `lumen test`
  all report the warning through the existing warnings channel
  (`CompileOptions.warnings`), the same way `W_UNUSED` (spec 229) is.

## Success criteria

- **SC-001**: the example below compiles, runs, prints the expected output,
  and the warning appears once on the diagnostics phase.
- **SC-002**: a template literal with a raw newline produces no warning.
- **SC-003**: `zig build test` and `zig build conformance` stay green.

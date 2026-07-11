# Spec 175: `string.replace` / `replaceAll` with a regex

## Goal

Allow a regex as the pattern of `String.prototype.replace` (and `replaceAll`),
the common text-cleanup idiom:

```ts
"a1b2c3".replace(/[0-9]/g, "#");   // "a#b#c#"
"abc123def456".replace(/[0-9]+/g, "N");  // "abcNdefN"
"a  b   c".replace(/\s+/g, " ");   // "a b c"
```

Previously only a string pattern was accepted; a regex first argument reported
`E_TYPE_MISMATCH`, even though `regex.test(s)` already worked.

## Why additive, not breaking

Only makes previously-rejected programs compile. `s.replace("x", "y")` (string
pattern) is unchanged — it still replaces the first literal occurrence.

## Semantics

`s.replace(re, repl)` replaces regex matches in `s` with the literal string
`repl`. The regex's own `g` flag decides scope: with `g` every non-overlapping
match is replaced, without it only the leftmost one. The `i` flag is honored.
A zero-width match advances one byte so it cannot loop. `replaceAll` with a
regex behaves the same (the flag drives the count).

The replacement is a plain string; `$1`/`$&` substitution patterns are not
interpreted in V1.

## Implementation

- Runtime (`regex_rt.zig`): `__reRunEnd` reports a match's end offset; `__reFind`
  returns the leftmost `[start, end)` span at or after a position; `Compiled`
  gains a `global` flag parsed from `g`; `__reReplaceCompiled` / `replaceRegex`
  build the result string.
- Checker: a `replace`/`replaceAll` call whose first argument types as `regexp`
  takes a dedicated path, sets `regex_arg`, and flags `program.uses_regex`.
- Emit: `emitStringMethod` routes a `regex_arg` call to `replaceRegex(source,
  flags, receiver, repl)`.

## Requirements

- **FR-001**: `s.replace(/re/g, r)` replaces every match; `s.replace(/re/, r)`
  replaces the first.
- **FR-002**: The `i` flag is honored; the string-pattern form is unchanged.
- **FR-003**: A regex bound to a variable works as the pattern.

## Success Criteria

- **SC-001**: `"a1b2c3".replace(/[0-9]/g, "#")` -> `a#b#c#`;
  `"a1b2c3".replace(/[0-9]/, "#")` -> `a#b2c3`.
- **SC-002**: `"abc123def456".replace(/[0-9]+/g, "N")` -> `abcNdefN`;
  `"a  b   c".replace(/\s+/g, " ")` -> `a b c`.
- **SC-003**: `"Hello World".replace(/o/gi, "0")` -> `Hell0 W0rld`.
- **SC-004**: `"a-b-c".replace("-", "+")` (string pattern) -> `a+b-c`.
- **SC-005**: `zig build`, `zig build test`, and the `regex_rt.zig` unit test
  stay green.

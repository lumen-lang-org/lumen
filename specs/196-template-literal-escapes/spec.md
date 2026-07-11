# Spec 196: escape sequences in template literals

## Goal

Process backslash escape sequences in template literals, matching regular string
literals:

```ts
`line1\nline2`;   // two lines
`col1\tcol2`;     // tab-separated
`x\ty${n}`;       // escapes and interpolation together
```

Previously a template literal emitted `\n`/`\t` verbatim (a literal backslash
followed by the letter) while a regular `"..."` string decoded them — a silent
inconsistency.

## Root cause

Template text is stored raw (escapes verbatim). `emitStrLit` decodes escapes
before re-encoding for Zig, but `emitTemplateText` passed the backslash through
unchanged, so `\n` became `\\n` in the generated Zig — a literal backslash-n.

## Fix

`emitTemplateText` now decodes `\n`/`\t`/`\r`/`\0` and `\<char>` the same way
`emitStrLit` does, before re-encoding for the Zig format string. Interpolation
(`${…}`) and literal-brace escaping (`{` → `{{`) are unchanged.

## Why additive, not breaking

Turns a silently-wrong behavior correct. A template with no escape sequences is
unchanged; `\\` still yields a single backslash.

## Requirements

- **FR-001**: `\n`, `\t`, `\r` in a template literal produce the control
  characters, as in a regular string.
- **FR-002**: `\\`, `\"`, and interpolation are unchanged.

## Success Criteria

- **SC-001**: `` `a\nb` `` prints on two lines.
- **SC-002**: `` `x\ty${n}` `` (n=5) prints `x`, a tab, `y5`.
- **SC-003**: `` `back\\slash` `` -> `back\slash`; `` `val=${n} ok` `` still
  interpolates.
- **SC-004**: `zig build` and `zig build test` stay green.

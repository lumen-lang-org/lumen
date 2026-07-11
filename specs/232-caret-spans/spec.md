# Spec 232: token-width caret underlines + same-line warning suppression

## Goal

Underline the whole offending token, not just its first character:

```text
g.ts:1:1: error: undefined variable 'missingVariable'
  1 | console.log(missingVariable)
    | ^~~~~~~
```

## Semantics

- The caret line renders `^` followed by `~` covering the token at the caret
  column: an identifier run (alphanumeric/underscore) or a double-quoted
  string literal; anything else keeps the single `^`. Colored green on a TTY
  as before.
- Warnings are suppressed on any line that already carries an error in the
  same run — most importantly the error-recovery binding of a failed
  declaration, which would otherwise also warn "unused variable".

## Success Criteria

- **SC-001**: An identifier at the caret is underlined for its full length; a
  one-character token keeps a bare `^`.
- **SC-002**: `const x: i32 = "bad"` reports the type error with no unused
  warning; a genuinely unused variable on a clean line still warns.
- **SC-003**: `zig build` and `zig build test` stay green.

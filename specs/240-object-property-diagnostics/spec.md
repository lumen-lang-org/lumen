# Spec 240: object property diagnostics + break/return ASI fix

## Goal

Object-shape errors name the property and the type's real shape:

```text
main.ts:2:7: error: object literal has unknown property 'z' — `Point` has: x, y
main.ts:2:7: error: object literal is missing property 'y' (`i32`) required by `Point`
main.ts:3:1: error: `Point` has no property 'z' — did you mean 'x'?
```

Previously all three were a bare "type mismatch" / "unknown field".

Also fixes an ASI parser bug this probing surfaced: inside a switch,

```ts
case 1:
  console.log("one")
  break        // <- no semicolon
case 2:        // was: "expected end of statement, found a number"
```

`break` tried to read `case` on the next line as its label.

## Semantics

- An object literal against a named type reports the first unknown property
  with the type's declared property list, or the first missing required
  property with its type.
- A field read of an unknown property gets a did-you-mean over the type's
  declared fields (bounded edit distance), else the full property list.
- `break`/`continue` only accept a label on the same line, and `return` only
  takes a value starting on its own line (JS's restricted productions), so
  ASI ends the statement at the newline.

## Success Criteria

- **SC-001**: Unknown, missing, and misspelled properties each report the
  tailored message.
- **SC-002**: `break`-then-`case` without a semicolon parses; a switch in a
  function returning per-case still runs correctly (`label(2)` -> "two").
- **SC-003**: `continue` without a semicolon inside a loop parses and runs.
- **SC-004**: `zig build` and `zig build test` stay green.

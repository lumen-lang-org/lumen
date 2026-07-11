# Spec 235: diagnostics map to the original file across imports

## Goal

Point diagnostics at the file and line the user actually wrote, not at the
merged import-inlined source:

```text
util.ts:2:3: error: type mismatch: expected `i32`, got `string`
  2 |   return "not a number"
    |   ^~~~~~
```

Previously a program with local imports reported every error and warning
against the entry file with merged line numbers — an error inside `util.ts`
showed as a bogus `main.ts:N`.

## Semantics

The import expander records the origin (file, original line) of every line it
appends to the merged source; skipped lines (import statements, re-export
lists, stripped tests) record nothing, and a spliced module's lines record
their own file. Diagnostics and warnings translate the merged line through
this map for the displayed `file:line` and excerpt gutter; the excerpt text
itself reads from the merged source (identical content). Display paths are
normalized (no `././`). Single-file programs are unchanged.

Runtime errors still report merged positions (the generated binary embeds the
merged source); noted as a future improvement.

## Success Criteria

- **SC-001**: An error in an imported file reports `util.ts:<its line>` with
  the correct excerpt.
- **SC-002**: An error in the entry file after imports reports the entry
  file's own line numbers.
- **SC-003**: Warnings (e.g. unused import binding) map the same way.
- **SC-004**: Single-file diagnostics are byte-identical; `zig build` and
  `zig build test` stay green.

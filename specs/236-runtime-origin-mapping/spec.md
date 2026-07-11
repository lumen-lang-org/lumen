# Spec 236: runtime errors map to the original file across imports

## Goal

Runtime errors and stack traces in multi-file programs report the file the
user wrote, completing spec 235 (which covered compile-time diagnostics):

```text
util.ts:2:14: Uncaught Error: negative input
  2 |   if (n < 0) throw new Error("negative input")
    |              ^
    at risky (util.ts:2:14)
    at <main> (main.ts:3:1)
```

Previously the generated binary embedded the merged source and reported merged
line numbers against the entry file.

## Semantics

When the program has local imports, the generated binary embeds an origin
table (one `{file, line}` entry per merged line, built from the import
expander's line map). The panic handler resolves the failing position, the
excerpt gutter, and every stack frame through it. Programs without imports
emit an identity resolver and are unchanged. Display paths are normalized.

## Success Criteria

- **SC-001**: A throw inside an imported file reports `util.ts:<its line>`,
  and its stack frame shows the same; the `<main>` frame shows the entry
  file's own line.
- **SC-002**: Single-file programs produce identical output to before.
- **SC-003**: `zig build` and `zig build test` stay green.

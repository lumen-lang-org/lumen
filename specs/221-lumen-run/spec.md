# Spec 221: `lumen run`

## Goal

Compile and execute in one step:

```sh
lumen run app.ts
lumen run app.ts --port 8080     # trailing args forwarded to the program
lumen run --release-fast app.ts
```

Previously the only path was `lumen compile app.ts && ./app` — two steps for
the most common developer action.

## Semantics

`lumen run [--release-fast] <file.ts> [args...]`:

- compiles `<file.ts>` exactly like `lumen compile` (same modes, same
  diagnostics); a compile error prints the normal diagnostic and exits with
  that code without running anything;
- on success executes the produced `./<stem>` binary with inherited
  stdin/stdout/stderr, forwarding every argument after the source file;
- the process exit code is the program's exit code (`process.exit(3)` →
  `lumen run` exits 3).

`--release-fast` is accepted before the source file. Flags after the source
file belong to the program, not to lumen.

## Success Criteria

- **SC-001**: `lumen run hello.ts` compiles and prints the program output.
- **SC-002**: A compile error exits nonzero without executing.
- **SC-003**: The program's exit code is forwarded.
- **SC-004**: `lumen compile` / `watch` / `test` are unchanged; usage text
  lists the new command; `zig build` and `zig build test` stay green.

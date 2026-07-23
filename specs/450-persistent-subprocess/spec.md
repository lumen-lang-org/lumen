# Spec 450 — Persistent piped subprocess (`child_process.spawn` → `ChildProcess`)

## Problem

Today `child_process.spawnSync(cmd, args)` (spec 037) is **one-shot**: it spawns a
child, reads its stdout/stderr to completion, waits for exit, and returns
`{ stdout, stderr, status }`. It cannot keep a process open, so a Lumen program
cannot hold a conversation with a long-lived child.

MCP's stdio transport is exactly such a conversation: newline-delimited JSON-RPC
written to a child's stdin and read back from its stdout, many request/response
exchanges over one process lifetime. That is impossible with `spawnSync`.

This spec **adds** a persistent variant. It does not change `spawnSync`.

## Surface

```ts
child_process.spawn(command: string, args: string[]): ChildProcess

ChildProcess.write(data: string): void      // write raw bytes to the child's stdin
ChildProcess.writeLine(data: string): void  // write data + "\n" (the MCP framing)
ChildProcess.readLine(): string             // read one \n-delimited line from stdout; "" at EOF
ChildProcess.close(): void                   // close stdin, wait for the child to exit
```

`ChildProcess` is a long-lived read/write/close handle — the same shape as the
`Socket` type (spec 054). It is implemented file-for-file as a mirror of `Socket`:

- **Type**: a payload-less `process_type` variant of the `Type` union, spelled
  `ChildProcess`, lowering to `*LumenChildProcess`.
- **Producer**: `child_process.spawn` in `childProcessCallType` sets
  `program.needs_child_process_spawn` and returns `process_type`, exactly as
  `net.connect` returns `socket_type`.
- **Methods**: `childProcessMethod` validates `write`/`writeLine`/`readLine`/
  `close`, mirroring `socketMethod`. Setting `mc.container_type` lets the generic
  emit path lower `<recv>.<name>(<args>)` with zero new codegen.
- **Runtime**: `LumenChildProcess` holds an optional `std.process.Child` plus a
  buffered stdin writer and stdout reader kept on the handle, so `readLine()`
  pulls one line at a time instead of draining to completion.

### Line reading

`readLine()` returns the line **including** its trailing `\n`, and `""` only at
true end-of-stream. This matches `fs.createReadStream(...).readLine()` (spec 053):
stripping the terminator would make a genuine blank line and EOF both collapse to
`""`, breaking a `while (readLine() != "")` loop on blank input. It uses
`takeDelimiterInclusive`, which advances the reader past the delimiter — the
exclusive variant leaves `\n` buffered and would make every subsequent `readLine`
see a zero-length result (EOF), silently breaking multi-line conversations.

## In scope

- stdio pipes only: stdin + stdout piped and kept open; stderr inherited.
- The four handle methods above, plus `spawn` as the constructor.

## Out of scope

- No pseudo-terminal (pty).
- No signals or process control beyond `close()` (no `kill`, no timeout).
- No stderr capture (stderr is inherited so a child's diagnostics surface, and so
  an undrained stderr pipe can never deadlock the child).
- No async/await integration: `readLine` is a blocking read.

## Success criteria

- `zig build` and `zig build test` pass.
- A real round trip runs: spawn `cat`, `writeLine` a message, `readLine` it back,
  assert equality; two round trips on one child; `readLine` at EOF returns `""`.
- Conformance has a `test-run` case and a `compile-run` case (asserting stdout)
  wired into `build.zig`, plus `diagnostics` cases for bad arguments and unknown
  methods. No pre-existing conformance cases regress.

## Known limits (v1)

- A single stdout line longer than the 64KB reader buffer yields `""`
  (`StreamTooLong`).
- `close()` blocks in `wait()` until the child exits; a child that never
  terminates would hang it (no kill/timeout escape hatch yet).
- A failed spawn (bad command) degrades to a no-op handle: `write`/`writeLine`
  do nothing and `readLine` returns `""`. A caller cannot yet distinguish
  "process died" from "no output yet".
- The handle is single-consumer, like `Socket`.

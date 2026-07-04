# Tasks: Spec 053 stdio streams

- [x] T1 Read spec 046 (`LumenReadableStream`/`LumenWritableStream`) and spec
      050 (`process.*` checker shape) source directly; confirm
      `std.Io.File.stdin()`/`stdout()`/`stderr()` return a plain `File`
      (checked `lib/std/Io/File.zig` directly rather than assumed).

- [x] T2 Checker: `processCallType` (`src/lumen_check_stdlib.zig`) gains
      three zero-arg branches -- `process.stdin()` -> `.readable_stream_type`,
      `process.stdout()`/`process.stderr()` -> `.writable_stream_type`.
      Each sets `program.uses_io = true` and a new `program.needs_process_stdio`
      flag (plus `program.needs_fs_streams = true`, so the shared
      `LumenReadableStream`/`LumenWritableStream` struct definitions are
      guaranteed emitted even in a program that uses stdio streams but never
      calls `fs.createReadStream`/`createWriteStream`).

- [x] T3 `readableStreamMethod` gains `readLine()` -> `.string`, zero args.
      No emit change needed beyond this (generic `mc.container_type`
      dispatch in `lumen_emit.zig` already emits `obj.readLine()` for any
      method name once `container_type` is set). Terminator is kept, not
      stripped, so `""` unambiguously means true EOF -- see spec.md's "A
      real bug caught by testing" section for why a stripped-terminator
      first draft was wrong.

- [x] T4 AST: add `needs_process_stdio: bool = false` to `Program` in
      `src/lumen_ast.zig`, next to the existing `needs_fs_streams`/
      `needs_process_api` flags.

- [x] T5 Emit: three new `process.*` dispatch arms in `src/lumen_emit.zig`'s
      static-call chain (next to the existing `process.pid()`/`argv()`
      arms) emitting `__processStdin(__io)` / `__processStdout(__io)` /
      `__processStderr(__io)`.

- [x] T6 Runtime (`src/lumen_compiler.zig`):
      - Add `flush_each_write: bool = false` field to the existing
        `LumenWritableStream` struct (inside the `needs_fs_streams` block);
        `.write()` flushes after `writeAll` when the flag is set. Existing
        `fs.createWriteStream` path untouched (field defaults false).
      - Add `readLine()` method to `LumenReadableStream` using
        `takeDelimiterInclusive('\n')`, keeping the terminator (not
        stripped -- see spec.md), with explicit `EndOfStream` handling
        (drain `buffered()` for a final unterminated line) + dupe; `""`
        only on true EOF or missing file.
      - New `needs_process_stdio`-gated block (after the `needs_fs_streams`
        block, since it references those types) with
        `__processStdin`/`__processStdout`/`__processStderr` constructors
        calling `LumenReadableStream.__init`/`LumenWritableStream.__init`
        directly on `std.Io.File.stdin()`/`stdout()`/`stderr()` (no
        open/create step), setting `flush_each_write = true` on the two
        writable ones.

- [x] T7 `zig build`, then compile+run a `.ts` program covering:
      - `process.stdin()` line loop via `readLine()`, run under
        `echo "hello" | ./prog` and a multi-line heredoc -- verify real
        piped bytes come through, not a placeholder.
      - A blank line in the middle of piped input, and a final line with
        no trailing newline (`printf` with no `\n`) -- both must be
        returned as real content, not treated as premature EOF.
      - `process.stdout().write(...)` interleaved with `console.log(...)`
        in program order -- verify no reordering from buffering.
      - `process.stderr().write(...)` lands on fd 2, not fd 1 (verify via
        shell redirection, `2>/dev/null` vs `1>/dev/null`).
      - `.read()` (64KB-chunk, spec 046's original method) still works on
        `process.stdin()` directly, not just `readLine()`.
      - `fs.createWriteStream` regression check: writes still only appear
        after `.close()`, not per-call (proves `flush_each_write` default
        didn't leak into the file-backed path).

- [x] T8 `zig build test` and one full, clean, non-concurrent
      `zig build conformance` (206 passed / 0 failed).

- [x] T9 `website/stdlib.html`: quick-jump nav entry, `<h4 id="stdio-streams">`
      section, `<div class="api">` blocks for `process.stdin()`/`stdout()`/
      `stderr()` and `ReadableStream.readLine()`; validate with
      `python3 html.parser` afterward.

- [x] T10 One focused commit.

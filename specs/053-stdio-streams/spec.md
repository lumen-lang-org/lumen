# Spec 053: stdio streams -- `process.stdin`/`stdout`/`stderr`

## Goal

Close the single highest-value gap for CLI tools: there is currently no way
for a Lumen program to read piped/redirected stdin at all. Ship
`process.stdin()` / `process.stdout()` / `process.stderr()` as the exact
`ReadableStream`/`WritableStream` types spec 046 (Streams) already built for
`fs.createReadStream`/`createWriteStream`, wired to the process's real
stdin/stdout/stderr file descriptors instead of an opened file. Plus a
pragmatic line-reading primitive, since line-oriented input (one record per
line) is the overwhelmingly common CLI shape and the 64KB-chunk `.read()`
spec 046 shipped doesn't give a caller a line on its own.

## Why reuse spec 046's types verbatim, not a new type

`LumenReadableStream`/`LumenWritableStream` (`src/lumen_compiler.zig`,
`needs_fs_streams`) are already: a heap-allocated struct owning a
`std.Io.File.Reader`/`Writer` plus the `std.Io.File` itself, with `.read()`/
`.write()`/`.close()` method dispatch already wired through the checker
(`readableStreamMethod`/`writableStreamMethod` in
`src/lumen_check_stdlib.zig`) and emit (`mc.container_type` generic dispatch
in `src/lumen_emit.zig`, no per-type-name special casing needed). The only
thing tying those types to *files* is which constructor built them
(`__fsCreateReadStream`/`__fsCreateWriteStream`, which call
`std.Io.Dir.cwd().openFile`/`createFile`). `std.Io.File.stdin()`/`stdout()`/
`stderr()` (checked directly in
`lib/std/Io/File.zig`) return a plain `File` value, the same concrete type
`openFile`/`createFile` produce -- so three new constructors
(`__processStdin`/`__processStdout`/`__processStderr`) that skip the
open/create step and hand the real stdio `File` straight to the existing
`LumenReadableStream.__init`/`LumenWritableStream.__init` are enough. No new
checker type, no new emit branch beyond the three `process.*` call-site
dispatches themselves.

## A real bug this reuse would have silently shipped: unflushed stdout writes

`LumenWritableStream.write()` (spec 046) does `self.writer.interface.writeAll(chunk)`
with **no flush** -- correct for a file-backed stream, where buffering
until `.close()` is the whole point. Reusing it verbatim for
`process.stdout()`/`stderr()` would mean `process.stdout().write("x")`
followed by `console.log("y")` prints `y` *before* `x` (console.log's
`__consoleOut` flushes every call; the stdio-backed stream wouldn't flush
until an explicit, easy-to-forget `.close()` -- and closing fd 1/2 mid-
program is actively wrong besides). Confirmed this actually happens before
fixing it (see Verification). Fixed with one new field on the existing
struct rather than a new type: `flush_each_write: bool = false` on
`LumenWritableStream`, defaulted off (so `fs.createWriteStream`'s existing
buffered-until-close behavior is byte-for-byte identical, zero regression
risk), set to `true` only by the three new stdio writer constructors. A
`Process.stdout()`/`stderr()`-created stream flushes after every `.write()`
call, matching what a synchronous, blocking CLI-facing stream needs to look
like interleaved with other synchronous stdout writers.

`process.stdout()`/`stderr()`'s `.close()` is left as the inherited
behavior (flush + `file.close()`) rather than special-cased into a no-op:
Node's own `process.stdout.end()` closing the underlying fd is also
generally a documented footgun, not a safety rail Node builds in either;
matching spec 046's existing method contract exactly (`.close()` on a
stream is always "I'm done with this stream") stays simplest and most
predictable. Callers that don't want the fd closed simply don't call
`.close()` on the process streams -- process exit reclaims the fd anyway.

## Line reading: which shape, and why

**Shape chosen**: `ReadableStream.readLine()` -- `() -> string`, added to the
same `readableStreamMethod` dispatch spec 046 already established, available
on every `ReadableStream` (stdio- or file-backed alike; `fs.createReadStream(...).readLine()`
is exactly as valid as `process.stdin().readLine()`, since it's the same
Zig type either way). Returns the next line **including its trailing
terminator** (`\n`, or `\r\n` if the source used CRLF); `""` means true
end-of-stream, nothing more to read.

**A real bug caught by testing, not assumed away: terminator-stripping
would make a blank line indistinguishable from EOF.** The first
implementation attempt stripped the trailing `\n`/`\r\n` before returning
(matching `.read()`'s "`""` means EOF" convention, and what the original
draft of this section said). That's actively wrong for line-oriented text:
`.read()`'s empty-chunk/EOF collapse is safe because no current Lumen
`fs` writer produces a genuine zero-byte chunk mid-stream, but ordinary
text has blank lines constantly (a blank line between paragraphs, a
trailing blank line before EOF, an empty CSV row). Once the terminator is
stripped, a real blank line's content and true EOF's content are both the
zero-length string -- indistinguishable, so a caller's
`while (readLine() != "") { ... }` loop silently stops at the first blank
line in the input, treating it as end-of-stream. Confirmed directly: piping
`printf 'a\n\nb\n'` (a blank second line) through a stripped-terminator
`readLine()` implementation stopped after `"a"`, never seeing `"b"`, before
this was caught and fixed -- not a theoretical concern. **Fix**: keep the
terminator on every real line (`std.Io.Reader.takeDelimiterInclusive`
already includes it); a genuinely blank line then returns `"\n"` (length 1,
not `""`), so only true end-of-stream is ever the empty string. A caller
that wants the terminator stripped calls the existing `.trim()` string
method itself (`line.trim()`); this method deliberately doesn't strip it
automatically, trading one extra caller-side `.trim()` call for a return
value where `""` unambiguously means "no more lines" -- see the
"Rejected alternative" below for why a nullable/optional return wasn't
used instead.

**Final unterminated line (real EOF with no trailing `\n`) is still
returned correctly, without a synthetic terminator appended**: confirmed by
testing `printf 'no newline at end'` (no `\n` at all) through a real piped
run -- `takeDelimiterInclusive` raises `error.EndOfStream` in this case
(checked directly in `lib/std/Io/Reader.zig`: `peekDelimiterInclusive`'s
internal `fillMore` loop propagates `EndOfStream` as soon as the
underlying read hits real end-of-file while still searching for the
delimiter, rather than returning the accumulated bytes -- this was
initially assumed to work the other way and was wrong; the `takeDelimiter`
test block in the same file confirms the same EOF-as-terminator-substitute
behavior only exists on the *separate* `takeDelimiterExclusive`/
`takeDelimiter` functions, not `*Inclusive`). `readLine()` therefore
catches that specific `error.EndOfStream`, drains whatever partial bytes
are still sitting in the reader's own buffer via `buffered()`/`toss()`
(the bytes read so far before hitting real EOF are not discarded by
`fillMore`, just not returned by `takeDelimiterInclusive` itself), and
returns that leftover verbatim (no `\n` was ever there to add). A second
call after that returns `""`.

**Rejected alternative -- return an optional/nullable string
(`string | null`) instead, with `null` meaning EOF and `""` meaning a real
blank line**: the technically cleanest signal, and the one Zig's own
`takeDelimiter` (a different stdlib function, not used here) exposes
natively (`?[]u8`). Rejected for this pass because Lumen's optional-type
support in method-return position for a built-in type's method (as opposed
to a user function) is not confirmed to compose cleanly with the existing
`readableStreamMethod`/`writableStreamMethod` return-type dispatch without
its own separate design pass; keeping the terminator gets the same
correctness property (unambiguous EOF) using only the `string` return type
already proven to work end-to-end for every other stream method. Worth
revisiting if a future spec adds real optional-string support to a
built-in method position.

**Rejected alternative 1 -- Node's `readline.createInterface(...)` (event-
based, `.on('line', cb)`)**: out of scope. Node's `readline` pumps its
`'line'` events off the same async I/O event loop that also feeds sockets/
timers; replicating that here would need a background task continuously
polling stdin's fd through `libxev`'s event loop and invoking a Lumen
closure per line asynchronously -- a real, separate "async line source"
feature, not a synchronous stream method. Every I/O primitive Lumen has
shipped that touches a real byte stream synchronously (`.read()`/`.write()`
themselves, `fs.readFileSync`, `fs.createReadStream`) is blocking-call-
shaped, not event-shaped; a callback-driven `readLine` would be the only
inconsistent one in the whole stdio/stream surface, for a feature (CLI
piped-input line processing) that a simple blocking loop
(`while (true) { const line = process.stdin().readLine(); if (line == "") break; ... }`)
already serves completely -- Lumen V1 has no background/async CLI program
shape (no timers running after `main` returns, no persistent event loop
except inside `http.createServer`) that a `'line'`-event API would even
have a natural place to fire into outside of one already-blocking read
loop.

**Rejected alternative 2 -- a bare `process.readLineSync()` top-level
function** (no `ReadableStream` involved at all, mirroring
`fs.readFileSync`'s naming): rejected because it would only ever make sense
bound to stdin specifically, duplicating exactly the read-buffering
`LumenReadableStream` already owns (an internal `std.Io.File.Reader` with
its own backing buffer) in a second, parallel place, and forecloses the
(real, immediately useful) case of line-reading a `fs.createReadStream`-
opened file. A method on the stream type composes with everything spec 046
already shipped for free.

**Implementation**: `Reader.takeDelimiterInclusive('\n')` -- the same
primitive `__httpCreateServer`'s request-line/header parsing
(`src/lumen_compiler.zig`, both the threaded and wasm32 server bodies)
already uses for exactly this "read up to and including the next `\n`"
shape over a `std.Io.Reader` interface, plus explicit `EndOfStream`/
buffered-leftover handling for the final-unterminated-line case -- both
worked out and verified against real `lib/std/Io/Reader.zig` behavior in
the "A real bug caught by testing" and "Final unterminated line" sections
above (the mechanics, not repeated here). `LumenReadableStream` already
carries a `reader: std.Io.File.Reader` with a live `.interface` from spec
046's `__init`, reused as-is. The "no file" (`self.file == null`, the same
missing/unopenable-file fallback spec 046 established for `.read()`) case
also returns `""`, matching `.read()`'s existing "never crash, return the
empty fallback" contract.

## API (v1 scope)

| Function | Type | Notes |
| --- | --- | --- |
| `process.stdin()` | `() -> ReadableStream` | wraps `std.Io.File.stdin()`; every call returns a **new** stream instance wrapping the same fd (no caching) -- matching how `fs.createReadStream` also allocates fresh each call; calling `process.stdin()` twice and reading from both is unusual but not actively guarded against, same as Node not stopping two consumers of `process.stdin` from fighting over the same bytes |
| `process.stdout()` | `() -> WritableStream` | wraps `std.Io.File.stdout()`; flushes after every `.write()` |
| `process.stderr()` | `() -> WritableStream` | wraps `std.Io.File.stderr()`; flushes after every `.write()` |

| Method (new) | Type | Notes |
| --- | --- | --- |
| `ReadableStream.readLine()` | `() -> string` | next line, terminator (`\n`/`\r\n`) **kept, not stripped** (so `""` unambiguously means true EOF, not a blank line -- call `.trim()` for a stripped line); available on every `ReadableStream`, not stdin-specific |

## Requirements

- **FR-001**: `process.stdin()` reads real piped/redirected data -- verified
  by actually running a compiled binary with `echo ... | ./prog` and a
  multi-line heredoc, not just compiling.
- **FR-002**: `process.stdout()`/`process.stderr()` writes are flushed
  per-call and interleave correctly, in program order, with `console.log`
  output in the same run.
- **FR-003**: `ReadableStream.readLine()` returns `""` if and only if the
  stream is truly exhausted -- a genuinely blank input line must return a
  non-empty result (its kept terminator), and a final unterminated line
  (no trailing `\n`) must be returned intact rather than dropped.
- **FR-004**: `fs.createReadStream`/`createWriteStream`'s existing behavior
  (spec 046) is unchanged -- `.write()` on a file-backed `WritableStream`
  still buffers until `.close()`, not flushed per-call.
- **FR-005**: `zig build test` passes and one full, clean, non-concurrent
  `zig build conformance` run shows 206 passed / 0 failed.

## Not planned (this pass)

| Item | Why |
| --- | --- |
| Node's event-based `readline.createInterface`/`.on('line', cb)` | needs a background async line-pump feeding closures off the event loop; every synchronous stdio primitive this spec builds on is blocking-call-shaped, and a plain `while` loop over `readLine()` already covers the CLI line-processing use case without inventing a new async shape -- see "Line reading" above |
| `process.stdin.isTTY` / raw mode / terminal control | no terminal-mode API exists anywhere in Lumen yet; a separate, later feature if interactive (non-piped) CLI input is ever in scope |
| Caching a single shared stdin/stdout/stderr stream instance across calls | each call allocates a fresh wrapper around the same fd today (see API table); a real optimization, not required for correctness at this scope |
| `process.stdout().write()` returning a backpressure signal (Node's `bool` return) | `.write()` here is synchronous/blocking (spec 046's model throughout), there is no backpressure to signal |

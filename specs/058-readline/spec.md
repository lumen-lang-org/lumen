# Spec 058: readline -- a cheap follow-up now that stdin exists

## Goal

Spec 053 shipped `process.stdin()` and `ReadableStream.readLine()`, but
explicitly deferred Node's event-based `readline.createInterface()`/
`.on('line', cb)` interface, since it needs a background async line-pump
this codebase doesn't have. What spec 053 left on the table -- and what
was blocking it -- was purely "there's no stdin to read from at all"; now
that stdin exists, the single most common `readline` use case (prompt the
user, block for one line of input) is a thin, synchronous wrapper over
what already shipped. This spec is that wrapper: one function, not a new
subsystem.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `readline.question(prompt)` | `string -> string` | Writes `prompt` to `process.stdout()` (no trailing newline added), then blocks reading one line from `process.stdin()`. **Deviation from spec 053's own `readLine()`**: the trailing newline is stripped before returning -- `readLine()` deliberately keeps it (its own "blank line vs. EOF" design), but `question()`'s whole point is to hand back the text the user typed, matching Node's own `readline.question()` callback value. At true end-of-stream (piped input exhausted, or a closed terminal), returns `""` -- the same convention `readLine()` itself uses for EOF, and the only sane synchronous fallback where Node's real API would instead emit a `'close'` event and never invoke the callback |

## Design notes

- **Why one flat function, not `readline.createInterface()`**: every
  synchronous stdio primitive this and spec 053 are built on
  (`.read()`/`.write()`/`.readLine()`) is a blocking call, not an
  event-driven one -- there is no background thread pumping stdin and
  invoking a JS-style callback on each line. `question()` fits that shape
  exactly (block, return); an `Interface` object with `.on('line', ...)`
  would need the same async line-pump spec 053 already ruled out, so it's
  not attempted here either.
- **Newline stripping is the one real design decision**: `readLine()`
  keeps the terminator so a genuinely blank input line (`"\n"`) stays
  distinguishable from true EOF (`""`) -- that's spec 053's fix for a real
  bug it found. `question()` doesn't need that distinction (its return
  value is "what did the user type", full stop), so it strips exactly one
  trailing `\r\n` or `\n` (matching typical line-ending handling) before
  returning, giving callers the ergonomic value they actually want without
  re-litigating `readLine()`'s own EOF-safety design.
- **Reuses `process.stdin()`/`process.stdout()` directly** -- no new stream
  type, no new runtime struct. The entire runtime addition is one function
  that calls the two constructors spec 053 already shipped and calls
  `.write()`/`.readLine()` on the results.

## Verification

A real `.ts` program, compiled and run through `zig-out/bin/lumen`, driven
with real shell piping (not just a compile check):
- `printf 'Ada\n' | ./prog` where `prog` does
  `const name = readline.question("Name: "); console.log("Hi " + name);`
  -- confirms the prompt appears on stdout, the piped answer is read, and
  the echoed value has no stray newline baked in (i.e. `"Hi Ada"` on one
  line, not `"Hi Ada\n"` visibly breaking the following output).
  `readline.question()`'s own newline-stripping is byte-verified via
  string length/equality in the test program, not just an eyeballed
  terminal print.
- A multi-line heredoc through two consecutive `question()` calls in one
  program, confirming the second call reads the second line, not a
  leftover/duplicate of the first.
- Piped input exhausted before a `question()` call -- confirms it returns
  `""` rather than blocking forever or crashing.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| `readline.createInterface()` / `.on('line', cb)` | a background async line-pump; already deferred by spec 053 for the same reason, not re-litigated here |
| Input history / line editing (arrow-key recall, tab completion) | needs real terminal raw-mode handling; no terminal-mode API exists anywhere in Lumen yet (also noted as out of scope in spec 053) |
| A default/fallback value parameter on `question()` | a real, separable ergonomic addition once there's a concrete caller need; `?? "default"` on the result already covers the common case today |

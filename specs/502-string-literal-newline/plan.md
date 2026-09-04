# Plan: 502 raw newline in string literal

## Where it lives

- `src/lumen_lexer.zig:291-312` — the two string scanners. Record whether a
  `\n`/`\r` was consumed; the token gets a `raw_newline: bool` flag (or the
  lexer pushes the warning directly if it already holds a diagnostics sink —
  check how `Regex` errors at `:19` are reported and follow that channel).
- Warnings are collected in `CompileOptions.warnings`
  (`src/lumen_emit.zig:1448`) and printed by `src/lumen.zig`; spec 229 added
  `W_UNUSED` and is the template for a new warning code.
- `src/lumen_emit.zig:108 emitStrLit` already escapes control bytes for Zig;
  confirm `\n` is escaped (it is, or no such program would have compiled) and
  add a unit test pinning it.

## Approach

1. Lexer: while scanning, set a flag on the token when a byte < 0x20 that is
   `\n` or `\r` is copied into the literal.
2. Parser: when it builds the string literal expression, if the flag is set,
   append a `Diag` with code `W_STRING_NEWLINE` to the warnings list (parser
   has access to the program's diagnostics; see how 229 threads
   `options.warnings` through `check.checkProgram`).
3. Conformance case with phase `diagnostics` expecting the warning text, and
   a `compile-run` case pinning the output.

## Risks

None of substance. The only decision is warning vs. error, and the spec
picks warning so no released program breaks.

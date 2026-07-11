# Spec 217: automatic semicolon insertion (no-semicolon style)

## Goal

Accept the common no-semicolon TypeScript style:

```ts
const a = 1
const b = 2
console.log(a + b)

function f(n: i32): i32 {
  const y = n * 2
  return y
}
```

Previously every statement required a literal `;`; pasted no-semicolon code
failed immediately — the single biggest barrier to compiling existing TS.

## Semantics

A statement terminator is satisfied by any of:
- a literal `;` (consumed, as before);
- the next token starting on a **later line** than the statement's last token;
- the next token being `}` (end of block);
- end of file.

Anything else (a same-line continuation without `;`) is still a syntax error.
The `for (init; cond; update)` header separators remain strict `;` — ASI never
applies inside a for header, matching JS.

Greedy expression parsing is unchanged: a multiline expression
(`1 +\n 2`, a method chain broken across lines with leading `.`) still parses
as one expression because the parser only checks for a terminator *after* the
expression completes.

## Implementation

- Parser tracks `prev_line` (line of the last consumed token) alongside
  `cur_line`.
- A new `expectSemi()` implements the terminator rule; all ~35 statement-
  terminator `expectOp(';')` sites across `lumen_parser.zig`,
  `lumen_parser_expr.zig`, and `lumen_parser_decl.zig` now call it. The three
  for-header separators keep `expectOp(';')`.
- The token peek helpers save/restore `prev_line`.

## Why additive, not breaking

Code with semicolons parses exactly as before (the `;` branch is checked
first). Only previously-rejected no-semicolon programs now compile.

## Success Criteria

- **SC-001**: Multi-statement no-semicolon programs (decls, reassignment,
  `x++`, control flow, classes, interfaces, throw/try) compile and run.
- **SC-002**: Method chains split across lines and multiline arithmetic still
  parse as one expression.
- **SC-003**: Semicolon-style and mixed-style code is unchanged.
- **SC-004**: `for (let i = 0; i < 3; i++)` still requires its header `;`s.
- **SC-005**: `zig build` and `zig build test` stay green.

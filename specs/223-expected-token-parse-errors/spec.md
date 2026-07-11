# Spec 223: parse errors say what was expected

## Goal

Replace the bare `syntax error` with what the parser expected and what it
found:

```text
g.ts:1:13: error: expected end of statement (';' or a newline), found 'const'
g.ts:2:1: error: expected ']', found 'console'
g.ts:1:14: error: expected ':', found 'i32'
g.ts:3:1: error: expected '}' to close this block, found end of file
```

Previously nearly every parse failure printed only `syntax error` with a
caret.

## Semantics

- `expectOp('x')` failures report `expected 'x', found <token>`, where the
  found token renders as its text (`'const'`, `'=>'`) or a category
  (`a number`, `a string`, `end of file`).
- `expectSemi()` failures report
  `expected end of statement (';' or a newline), found <token>`.
- An unterminated `{ ... }` block reports
  `expected '}' to close this block, found end of file` instead of failing
  inside the next statement parse.

These three helpers cover the large majority of parse failure sites; paths
that fail without going through them keep the generic message.

## Success Criteria

- **SC-001**: A missing `)`, `]`, `:`, and `}` each name the expected token
  and the found token.
- **SC-002**: Two statements on one line without `;` report the
  end-of-statement expectation.
- **SC-003**: Valid programs are unaffected; `zig build` and `zig build test`
  stay green.

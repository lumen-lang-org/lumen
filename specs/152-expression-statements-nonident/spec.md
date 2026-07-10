# Spec 152: expression statements not starting with an identifier

## Goal

Allow an expression statement whose first token is not an identifier — most
usefully a method call on an array or string literal, or on a parenthesized
expression:

```ts
["a", "b", "c"].forEach(s => console.log(s));
[1, 2, 3].forEach(x => console.log(x * 10));
"hello".split("").forEach(c => console.log(c));
```

Previously the statement parser rejected any statement that did not begin with
an identifier (or `++`/`--`), so these were syntax errors.

## Why additive, not breaking

Only makes previously-rejected programs parse. Identifier-led statements and all
keyword statements are unchanged.

## Semantics

When a statement's leading token is `[`, `(`, a string/number/float literal, or
a template literal, it is parsed as an expression statement (the expression
followed by `;`). This covers method calls and side-effecting chains on literal
receivers. `{` is intentionally excluded (it remains reserved for block/object
disambiguation).

## Requirements

- **FR-001**: A statement beginning with an array literal, string/number literal,
  template, or `(` is parsed as an expression statement.
- **FR-002**: Identifier-led and keyword statements are unchanged.

## Success Criteria

- **SC-001**: `["a","b","c"].forEach(s => console.log(s));` prints `a`,`b`,`c`.
- **SC-002**: `[1,2,3].forEach(x => console.log(x * 10));` prints `10`,`20`,`30`.
- **SC-003**: `"hello".split("").forEach(c => console.log(c));` prints each
  character.
- **SC-004**: `zig build` and `zig build test` stay green.

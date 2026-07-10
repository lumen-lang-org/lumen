# Spec 156: identifier-led expression statements

## Goal

Allow an expression statement that begins with an identifier and continues into
an operator — most usefully a ternary used for its side effects:

```ts
x > 0 ? console.log("positive") : console.log("negative");
a.length > 2 ? console.log("big") : console.log("small");
n % 2 === 0 ? console.log("even") : console.log("odd");
```

Previously an identifier-led statement had to be a call, member access, or
assignment; anything continuing with a binary/ternary operator
(`x > 0 ? ...`) was a syntax error.

## Why additive, not breaking

Only makes previously-rejected programs parse. Assignments (`x = ...`,
`obj.field = ...`), calls (`f(...)`), and method-call statements (`a.m(...)`)
parse exactly as before.

## Semantics

When a statement starts with an identifier and is not an assignment, a
declaration, or a keyword statement, the parser rewinds to the identifier and
parses the whole expression as an expression statement. This covers ternary,
comparison, and other operator-led continuations after an identifier or member
access (`a.length > 2 ? ...`).

## Requirements

- **FR-001**: `<expr>;` where `<expr>` starts with an identifier and contains a
  ternary/binary operator parses as an expression statement.
- **FR-002**: Assignments and member assignments still parse as assignments.
- **FR-003**: Call and method-call statements are unchanged.

## Success Criteria

- **SC-001**: `x > 0 ? console.log("positive") : console.log("negative");` runs
  the selected branch.
- **SC-002**: `a.length > 2 ? console.log("big") : console.log("small");` works.
- **SC-003**: `y = 20;` and `a.forEach(v => console.log(v));` still work.
- **SC-004**: `zig build` and `zig build test` stay green.

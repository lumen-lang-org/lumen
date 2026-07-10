# Spec 147: braceless control-flow bodies

## Goal

Allow a single unbraced statement as the body of `if`/`else`, `while`, `for`,
`for...of`, and `for...in`, as in JavaScript/TypeScript:

```ts
if (n < 2) return n;
for (let i = 0; i < 5; i++) sum += i;
for (const ch of s) if (ch >= "0" && ch <= "9") digits += ch;
while (n > 0) n--;
if (x > 5) console.log("big"); else console.log("small");
```

Previously every control-flow body required braces, so `if (n < 2) return n;`
(and the common recursive/guard-clause style) was a syntax error.

## Why additive, not breaking

Only makes previously-rejected programs parse. A braced `{ ... }` body parses
exactly as before.

## Semantics

A control-flow body is either a `{ ... }` block or a single statement, which is
treated as a one-statement block. This applies to `if`, `else`, `while`, the
C-style `for`, `for...of`, and `for...in`. (`do ... while`, `try`/`catch`/
`finally`, and `defer` still require braces.)

## Requirements

- **FR-001**: An unbraced single statement is a valid body for `if`, `else`,
  `while`, `for`, `for...of`, and `for...in`.
- **FR-002**: `else if` chaining is unchanged.
- **FR-003**: Braced bodies are unchanged.

## Success Criteria

- **SC-001**: A recursive `fib` using `if (n < 2) return n;` compiles;
  `fib(10)` -> `55`.
- **SC-002**: `for (let i = 0; i < 5; i++) sum += i;` gives `sum == 10`.
- **SC-003**: `for (const ch of s) if (...) digits += ch;` extracts characters;
  `while (n > 0) n--;` runs; `if (x > 5) ...; else ...;` selects a branch.
- **SC-004**: `zig build` and `zig build test` stay green.

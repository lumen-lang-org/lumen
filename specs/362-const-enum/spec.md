# 362 — `const enum` declarations

## Problem

`const enum E { ... }` was a parse error (`expected '=', found 'E'`): the `const`
keyword routed straight into variable-declaration parsing, which then choked on
the enum name.

## Change

`lumen_parser.zig`: added a `peekIsKw(word)` lookahead helper (saves/restores
lexer + token state, mirroring `peekIsColon`). In statement dispatch, `const`
immediately followed by `enum` consumes the `const` and parses a normal enum.

Lumen already inlines every enum member at its use site (enum decls emit no
runtime table — members lower to constants), so a `const enum` — whose whole
point in TypeScript is that inlining — lowers identically to a regular `enum`.
No checker or emitter change needed.

## Verified

`zig build` + `zig build test` green. Probes:

- `const enum E { A, B, C }` → `E.B, E.C` prints `1 2`.
- `const enum Dir { Up = "up", Down = "down" }` → `Dir.Up` prints `up`.
- `const enum S { On, Off }` in an exhaustive `switch` returns `off`.
- Regular `const x = 5;` and regular `enum R { X, Y }` both still work.

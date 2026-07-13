# 386 — Computed enum member values

## Problem

Numeric enum members could only be a bare literal or auto-incremented. A
constant expression — including the common flag-enum shift pattern — failed:

```ts
enum Flags { None = 0, Read = 1, Write = 1 << 1, Exec = 1 << 2 }  // syntax error
enum E { A = 1, B = A * 2, C = B * 2 }                            // syntax error
```

## Change

`lumen_parser_decl.zig`, enum member parsing: a numeric initializer that isn't a
lone string is parsed as a full expression and constant-folded at compile time
by `foldEnumConst` over integer literals, references to previously-defined
members of the same enum, unary `-`/`~`, and the binary operators
`+ - * / % & | ^ << >>`. The folded integer becomes the member value and seeds
the auto-increment for any following bare members. String enums and plain
auto-incremented enums are unchanged.

## Verified

`zig build` + `zig build test` green. Probes:

- `enum E { A = 1, B = A * 2, C = B * 2 }` → `1 2 4`.
- `enum Flags { …, Write = 1 << 1, Exec = 1 << 2 }` → `2 4`.
- `enum E { Base = 10, Next = Base + 5 }` → `15`.
- Plain (`Red, Green, Blue`), explicit (`A = 5, B = 10`), and string
  (`Up = "up"`) enums all unchanged.

## Boundary

Folding covers integer arithmetic/bitwise expressions over literals and earlier
members. Forward references, non-integer expressions, and division by zero are
rejected at parse time.

# Spec 339 — Relational comparison of numeric enums

## Goal

Allow relational operators between values of the same numeric enum:

```ts
enum Priority { Low = 1, Medium = 5, High = 10 }
console.log(Priority.Low < Priority.High);   // true

enum Level { A, B, C }
function ge(x: Level, y: Level): bool { return x >= y; }
```

## Motivation

Numeric enums are `i32`-backed, but a comparison between two enum values
(`x >= y`) kept the enum type as the operand type, so the relational check
rejected it with "`>=` needs numeric operands, got `Level`". Equality already
worked; ordering did not.

## Behavior

Two values of the same numeric enum compare — both relational (`<`, `>`, `<=`,
`>=`) and equality — as their `i32` backing. String enums still support only
`==`/`!=`; a relational operator on a string enum is a clear error. Comparing an
enum with its backing scalar (spec 294) is unchanged.

## Implementation

- `src/lumen_check_expr.zig`: the `.cmp` handler adds a case for two operands of
  the same numeric enum, comparing them as `i32`.

## Verification

- `zig build` and `zig build test` green.
- `Priority.Low < Priority.High` and `x >= y` over a numeric enum run; enum
  equality is unchanged; a relational operator on a string enum errors.

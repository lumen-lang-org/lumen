# Spec 316 — Exhaustive `switch` over an enum

## Goal

A `switch` that covers every member of an enum should be recognized as
exhaustive, so a following value `return` is not flagged as missing:

```ts
enum Color { Red, Green, Blue }
function label(c: Color) {
  switch (c) {
    case Color.Red: return "r";
    case Color.Green: return "g";
    case Color.Blue: return "b";
  }                                 // no default needed
}
```

## Motivation

Exhaustiveness was only computed for string-literal unions (spec 266). An enum
`switch` with no `default` — even one covering all members — was treated as
non-exhaustive, so the function reported `not all code paths return a value`,
forcing a redundant `default`.

## Behavior

When a `switch` over an enum type has no `default` clause, it is exhaustive iff
every enum member appears as a `case E.Member:`. An exhaustive switch satisfies
the return-flow checker and lowers with an `else unreachable` guard (the existing
mechanism for literal-union switches). A switch missing a member is still
non-exhaustive and a following return is required.

## Implementation

- `src/lumen_check_stmt.zig`: after the string-literal-union exhaustiveness check,
  an enum switch type resolves its members via the enum table and sets
  `exhaustive` when all are covered by cases.

## Verification

- `zig build` and `zig build test` green.
- A switch covering all enum members needs no `default` and returns cleanly; a
  switch missing a member still reports `E_MISSING_RETURN`; a switch with a
  `default` is unchanged.

# Spec 326 — Non-null assertion operator `x!`

## Goal

Support the postfix non-null assertion:

```ts
const x: i32 | null = 5;
console.log(x! + 1);              // 6

type P = { name?: string };
const p: P = { name: "hi" };
console.log(p.name!.length);      // 2

const m = new Map<string, i32>();
m.set("a", 10);
console.log(m.get("a")! + 5);     // 15
```

## Motivation

`expr!` is a very common TypeScript idiom for asserting that an optional value is
present. It previously failed to parse (`expected ';', found '!'`).

## Behavior

- `x!` unwraps an optional operand to its non-optional inner type. It chains with
  the other postfix forms (`a!.b`, `a.b!`, `m.get(k)!`).
- On a non-optional operand it is a no-op (accepted, type unchanged).
- At runtime an assertion on a `null` value panics (Zig's `.?`), rather than
  silently continuing — stricter than TypeScript's erase-only semantics.
- The single-`!` postfix is distinguished from the `!=`/`!==` comparison operators
  and the prefix logical-not `!x`, all of which are unchanged.

## Implementation

- `src/lumen_ast.zig`: a `non_null` expression `{ inner, unwraps }`.
- `src/lumen_parser_expr.zig`: the postfix loop consumes a trailing single `!`.
- `src/lumen_check_expr.zig`: types `x!` as the unwrapped operand type and records
  whether it actually unwraps an optional.
- `src/lumen_emit.zig`: emits `(inner).?` when it unwraps, else the operand
  unchanged.
- `src/lumen_types.zig`, `src/lumen_check_generics.zig`, `src/lumen_emit_analysis.zig`,
  `src/lumen_opt.zig`: the new variant is handled in `inferExprType`, `cloneExpr`,
  the throw/`this`/name-usage walkers, and the accumulator analyses.

## Verification

- `zig build` and `zig build test` green.
- `x!`, `p.name!.length`, `m.get(k)!`, and a no-op `x!` on a non-optional all run
  correctly; a `!` on a null value panics; `!==` and prefix `!x` are unaffected.

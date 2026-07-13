# 400 — generic type aliases without a space before `=` (`type Box<T>={...}`)

## Problem

A generic type alias declared with no space between the closing `>` of its type
parameters and the alias `=` failed to parse:

```ts
type Box<T>={ v: T };          // syntax error at `>`
type Pair<A,B>={ a:A; b:B };   // syntax error
```

The lexer glues `>=` into a single comparison token, so `type Box<T>=` tokenizes
the `>` closing the type-parameter list together with the alias `=`.
`parseTypeParams` only accepted a bare `>` to close, so it errored — even though
the identical declaration *with* a space (`type Box<T> = { … }`) parsed and
worked fine. This is the same `>=`/`>>=` gluing already handled for generic
value positions by `consumeTypeArgClose` (spec 389).

## Approach

`parseTypeParams` (`lumen_parser_decl.zig`): when closing the parameter list,
accept the glued tokens and split them, mirroring `consumeTypeArgClose`:

- `>`  → consume it.
- `>=` → rewrite the current token to a bare `=`, leaving it for the caller's
  `expectOp('=')`.
- `>>` / `>>=` (a nested constraint like `<T extends Box<Y>>`) → peel one `>` and
  leave `>` / `>=` for this level.

## Verification

- `type Box<T>={ v:T }` + `Box<number>` → `5`.
- `type Pair<A,B>={ a:A; b:B }` + `Pair<number,string>` → `1x`.
- Spaced form (`type Box<T> = { … }`) still works.
- `x >= 3` comparison, generic classes, and `Map<K,V>=` field initializers
  unchanged.
- Full `zig build` + test suite green.

## Notes

This unblocks the common no-space spelling of generic record/alias
declarations. Mapped types *over a generic parameter*
(`type RO<T> = { [K in keyof T]: T[K] }`) and non-record generic aliases
(`type Opt<T> = T | null`) resolving through instantiation remain separate,
deeper type-level items, not addressed here.

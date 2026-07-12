# Spec 350 — Generic type aliases (`type X<T> = ...`)

## Goal

Parse and specialize generic `type` aliases:

```ts
type Pair<A, B> = { first: A; second: B };
type Box<T> = { value: T };

const p: Pair<i32, string> = { first: 1, second: "x" };
function unwrap<T>(b: Box<T>): T { return b.value; }
```

## Motivation

Generic `interface` declarations already carried type parameters, but a generic
`type` alias failed to parse (`expected '=', found '<'`) because the type-alias
parser skipped the type-parameter list. Generic record aliases are a core
modelling tool.

## Behavior

A `type` alias may declare type parameters after its name. The record-body form
(`type Pair<A, B> = { ... }`) registers as a generic template and is specialized
per use, the same machinery generic interfaces already used. Self-referential
aliases (`type Tree<T> = { value: T; children: Tree<T>[] }`) parse. Non-generic
aliases are unchanged.

## Implementation

- `src/lumen_parser_decl.zig`: `parseTypeDecl` parses `parseTypeParams` after the
  alias name and threads them into the record-body `type_decl`, so the
  declaration pass registers it as a generic template.

## Verification

- `zig build` and `zig build test` green.
- `Pair<i32, string>`, `Box<i32>` (as an annotation and through a generic
  function), and a recursive `Tree<T>` declaration all check and run; non-generic
  aliases are unaffected.

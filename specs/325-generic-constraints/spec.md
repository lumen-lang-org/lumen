# Spec 325 — Generic type-parameter constraints (`T extends ...`)

## Goal

Accept generic constraint syntax on functions, classes, and type aliases:

```ts
function longest<T extends { length: i32 }>(a: T, b: T): T {
  return a.length >= b.length ? a : b;
}
class Box<T extends object> { constructor(public v: T) {} }
```

## Motivation

Any `<T extends ...>` clause produced a `syntax error`, so idiomatic generic code
copied from TypeScript failed to parse.

## Behavior

The `extends <type>` constraint is parsed and ignored. Lumen monomorphizes
generics, so each specialization's body is already type-checked against the
concrete type argument — a use like `x.length` fails at specialization if the
concrete type lacks it. The constraint therefore documents intent without a
separate enforcement pass. Constraints of any shape are accepted: named types,
inline object types, unions, and generic instantiations, across multiple type
parameters (`<K extends string, V extends i32>`).

## Implementation

- `src/lumen_parser_decl.zig`: `parseTypeParams` consumes an optional `extends`
  clause after each type-parameter name, skipping a balanced type expression up
  to the next `,` or the closing `>`.

## Verification

- `zig build` and `zig build test` green.
- Constraints with a named interface, an inline object type, multiple
  parameters, and a class type parameter all parse; the generic bodies run
  correctly; unconstrained generics are unchanged.

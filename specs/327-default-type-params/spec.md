# Spec 327 — Default type parameters (`<T = ...>`)

## Goal

Accept a default on a generic type parameter, alone or with a constraint:

```ts
function make<T = i32>(x: T): T { return x; }
class Box<T = i32> { constructor(public v: T) {} }
function f<T extends i32 = i32>(x: T): T { return x; }
```

## Motivation

`<T = i32>` produced a `syntax error`, blocking generic declarations copied from
TypeScript. This complements spec 325 (constraints).

## Behavior

The `= <type>` default clause is parsed and ignored. As with constraints, Lumen
monomorphizes generics, so the concrete type comes from an explicit type argument
or from inference at each call site. The default documents intent and keeps the
syntax valid; it is not yet applied as a fallback when a type argument is omitted
and cannot be inferred.

## Implementation

- `src/lumen_parser_decl.zig`: `parseTypeParams` consumes an optional `= <type>`
  default after each type-parameter name (and after any `extends` constraint),
  skipping a balanced type expression up to the next `,` or the closing `>`.

## Verification

- `zig build` and `zig build test` green.
- A defaulted function type parameter, a constrained-and-defaulted parameter, and
  a defaulted class type parameter all parse and run.

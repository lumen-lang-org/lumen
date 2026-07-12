# Spec 334 — Interface inheritance (`interface B extends A`)

## Goal

Support extending one or more interfaces:

```ts
interface Named { name: string }
interface Aged extends Named { age: i32 }

const p: Aged = { name: "bob", age: 30 };   // both fields required
class Person implements Aged {
  constructor(public name: string, public age: i32) {}
}
```

Multiple parents are allowed: `interface P extends X, Y { z: i32 }`.

## Motivation

`interface B extends A` failed to parse (`expected '{', found 'extends'`), so
interface composition — a core TypeScript modelling tool — was unavailable.

## Behavior

An extending interface includes every parent interface's fields ahead of its own.
A field the child redeclares overrides the inherited one. The merged shape is
then used everywhere the interface is: object-literal assignment requires all
inherited fields, and a class may `implements` the extended interface. Extending
an unknown interface reports a clear error.

## Implementation

- `src/lumen_ast.zig`: `TypeDecl` gains `parents`.
- `src/lumen_parser_decl.zig`: the interface parser reads an optional
  `extends A, B, ...` clause.
- `src/lumen_check.zig`: the type-declaration pre-pass (which runs in source
  order, so parents are already registered) merges each parent's fields ahead of
  the interface's own, de-duplicating overridden names, before registering it.

## Verification

- `zig build` and `zig build test` green.
- Single- and multi-parent interface extension works; inherited fields are
  required in object literals and satisfiable by an `implements` class; extending
  an unknown interface errors clearly.

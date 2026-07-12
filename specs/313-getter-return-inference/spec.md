# Spec 313 — Return-type inference for `this.<field>` getters

## Goal

Infer the return type of a getter-style method whose body returns a class field:

```ts
class Point {
  constructor(public x: i32, public y: i32) {}
  getX() { return this.x; }   // inferred: i32
}
```

## Motivation

Spec 312 inferred method return types from parameters but not from `this`,
because the class fields are not queryable through the general expression-typing
path during the class-type pass. Returning a field is the single most common
un-annotated method shape, so it warranted a targeted resolution.

## Behavior

When an un-annotated method's first return is `this.<field>` and `<field>` is one
of the class's own fields or a property constructor parameter, the method's
return type is that field's declared type. Other `this`-based returns (inherited
fields, computed expressions) still fall to the annotate-guidance from spec 312.

## Implementation

- `src/lumen_check.zig`: a `thisFieldType` helper resolves `this.<field>` against
  the `ClassDecl`'s own fields and property constructor params; `fillClassTypes`
  consults it when the general inference path cannot type the return expression.

## Verification

- `zig build` and `zig build test` green.
- `return this.x` getters over a declared field and over a property constructor
  parameter infer and run; parameter-derived method returns (spec 312) are
  unchanged.

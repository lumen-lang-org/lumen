# Spec 336 — Intersection of named record types (`A & B`)

## Goal

Support a type alias that intersects named record types:

```ts
type A = { x: i32 };
type B = { y: i32 };
type C = A & B;                 // { x: i32; y: i32 }
const c: C = { x: 1, y: 2 };
```

More than two operands work: `type D = A & B & E`.

## Motivation

`type C = A & B` failed to parse (`expected ';', found '&'`). Intersecting record
types is a common way to compose shapes, and Lumen already had the field-merge
machinery from interface inheritance (spec 334).

## Behavior

An intersection alias is modelled like an interface extending each operand: the
operands' fields are merged into the resulting record. Every merged field is
required in an object literal (`{ x: 1 }` alone is a "missing property 'y'"
error), and referencing an unknown operand is a clear error. Operands must be
named record/interface types; inline object operands (`A & { y: i32 }`) are not
covered by this slice. Union aliases (`A | B`) are unchanged.

## Implementation

- `src/lumen_parser_decl.zig`: after the first alias member, an `&`-separated
  list produces a `type_decl` whose `parents` are the operand names (reusing the
  interface-inheritance representation) and whose own field list is empty.
- `src/lumen_check.zig`: the existing parent-field merge in the type-declaration
  pre-pass builds the combined record; its diagnostic wording is generalized to
  cover both `type` and `interface`.

## Verification

- `zig build` and `zig build test` green.
- Two- and three-way named intersections type and run; a missing field errors; an
  unknown operand errors; discriminated-union aliases and interface inheritance
  are unchanged.

# Spec 328 — Class fields with an inferred type

## Goal

Let a class field omit its type annotation when it has an initializer:

```ts
class Counter {
  count = 0;            // inferred: i32
  label = "idle";       // inferred: string
  inc() { this.count = this.count + 1; }
}
```

## Motivation

A class field required an explicit annotation (`count: i32 = 0`); the shorthand
`count = 0` failed with `expected ':', found '='`. Initializer-typed fields are
idiomatic TypeScript.

## Behavior

- A field written `name = expr` (no `: T`) takes its type from `expr`, inferred
  during the class-type pass — before methods and call sites are checked.
- Annotated fields (`x: i32 = 0`), initializer-typed fields, and mixes of both in
  one class all work.
- A field with neither an annotation nor an initializer is a clear error:
  "a class field needs a type annotation (`x: T`) or an initializer
  (`x = value`)".
- Works for generic classes too; a specialization infers the field from its
  (cloned) initializer via lightweight literal inference.

## Implementation

- `src/lumen_ast.zig`: `TypeField` gains an `init` expression (set only when the
  annotation is omitted).
- `src/lumen_parser_decl.zig`: the field parser makes the `: T` annotation
  optional when an `= expr` initializer follows, and errors when both are absent.
- `src/lumen_check.zig`: `fillClassTypes` infers an un-annotated field's type from
  its initializer (`exprType`, or `inferExprType` during a generic specialization
  with no `program`).
- `src/lumen_check_generics.zig`: `specializeClass` clones the field initializer
  and preserves field visibility/static/readonly modifiers.

## Verification

- `zig build` and `zig build test` green.
- Inferred `int`/`string` fields, annotated fields, and mixed classes run
  correctly; a field with no type and no initializer errors; a generic class with
  an inferred field instantiates and runs.

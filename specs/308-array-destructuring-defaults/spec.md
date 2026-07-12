# Spec 308 — Array destructuring defaults

## Goal

Support default values in array destructuring patterns:

```ts
const [a = 1, b = 2] = [10];   // a = 10, b = 2
```

## Motivation

`const [a = 1] = arr;` previously failed to parse (`expected ']', found '='`).
Element defaults are common when destructuring arrays that may be shorter than
the pattern.

## Behavior

A binding may carry `= <expr>`. When the source array has an element at that
position it is used; otherwise the default value is bound. The default must be
assignable to the array's element type.

```ts
const arr: i32[] = [5];
const [a = 1, b = 2] = arr;    // a = 5, b = 2
```

- Defaults are supported for plain positional array bindings only, not for the
  rest element (`...rest`) and not for object-pattern bindings.
- A default of the wrong type is a type error:
  `const [a = "no"] = [1];` reports `expected `i32`, got `string``.

## Implementation

- `src/lumen_ast.zig`: `DestructBinding` gains `default: ?*Expr`.
- `src/lumen_parser.zig`: after a positional array binding name, an optional
  `= <expr>` is parsed as the default.
- `src/lumen_check_stmt.zig`: the default is checked assignable to the element
  type.
- `src/lumen_emit_stmt.zig`: the binding lowers to
  `if (i < src.len) src[i] else <default>`.

## Verification

- `zig build` and `zig build test` green.
- `const [a = 1, b = 2] = [10]` runs to `a = 10, b = 2`; a shorter typed source
  uses the defaults; a wrong-typed default is rejected; rest and no-default
  patterns are unchanged.

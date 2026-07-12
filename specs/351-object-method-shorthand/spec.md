# Spec 351 — Object-literal method shorthand

## Goal

Accept method shorthand in an object literal, desugaring it to a function-typed
field:

```ts
type M = { add: (a: i32, b: i32) => i32; run: () => void };
const m: M = {
  add(a: i32, b: i32) { return a + b; },
  run() { console.log("go"); },
};
```

## Motivation

Object literals accepted `{ run: () => ... }` but not the method shorthand
`{ run() { ... } }`, which is common TypeScript. It failed to parse
(`expected '}', found '('`).

## Behavior

A `name(params) [: R] { body }` entry in an object literal desugars to
`name: (params) => { body }`. Object literals have no `this`, so such a method is
a plain closure over its parameters. Parameters are parsed like a function
signature, so they carry annotations (`add(a: i32, b: i32)`); a zero-parameter
method (`run()`) works too. The arrow value form (`run: () => ...`) is unchanged.

### Limit

Untyped method-shorthand parameters (`add(a, b) { ... }`) are not inferred from
the field's function type in this slice — annotate them, or use the arrow form.

## Implementation

- `src/lumen_parser_expr.zig`: when an object-literal key is followed by `(`, the
  parser reads a parameter list, optional return annotation, and block body, and
  stores the entry as a block-body arrow value.

## Verification

- `zig build` and `zig build test` green.
- A void method, an annotated `add(a, b)` returning a value, and a mixed
  object (data field + method) all check and run; the arrow-value form is
  unchanged.

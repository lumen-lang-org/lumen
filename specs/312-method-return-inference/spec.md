# Spec 312 — Return-type inference for class methods

## Goal

Extend return-type inference (specs 310, 311) to class methods:

```ts
class Calc {
  double(x: i32) { return x * 2; }   // inferred: i32
  positive(n: i32) { return n > 0; } // inferred: bool
}
```

## Motivation

Method bodies previously defaulted to a `void` return type when the `: T`
annotation was omitted, so a value-returning method failed with the confusing
`expected `void`` mismatch — the same gap free functions had.

## Behavior

- A method with no return annotation infers its return type from the first value
  `return <expr>` (parameters in scope), during the class-type pass so call
  sites observe the inferred type.
- A method that returns no value stays `void`.
- `async` methods still require an explicit `Promise<...>` return type.
- A return built from `this`/class fields is not inferable at this stage (the
  class fields are not yet queryable) and reports the actionable guidance to add
  an explicit annotation, now including `this`/class fields in the list of
  not-yet-covered cases.

## Implementation

- `src/lumen_parser_decl.zig`: the method parse path sets `infer_return` when the
  `: T` annotation is absent.
- `src/lumen_check.zig`: `fillClassTypes` infers an omitted method return type
  from the first return expression (params in a temporary scope), mirroring
  `declareFunction`; it takes a nullable `program` so the generic-specialization
  caller can skip inference.
- `src/lumen_check_stmt.zig`: the annotate-guidance message now also lists
  `this`/class fields.

## Verification

- `zig build` and `zig build test` green.
- Methods returning parameter-derived values infer and run; void methods
  unchanged; a `this`-based return gets the guidance message.

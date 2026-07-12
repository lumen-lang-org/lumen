# Spec 341 — Calling a function-typed class field

## Goal

Call a class field (or constructor property parameter) whose type is a function,
the same way it already works on records:

```ts
class C {
  handler: () => i32 = () => 42;
  run(): i32 { return this.handler(); }        // 42
}
class D {
  constructor(public cb: () => i32) {}
  run(): i32 { return this.cb(); }             // cb()
}
```

## Motivation

Calling a function-typed field on a record (`obj.greet()`) already rewrote to a
value call, but the same call on a class instance (`this.handler()`) went through
method resolution and failed with "`C` has no method 'handler'".

## Behavior

When a `receiver.name(args)` call finds no method `name` on the class (or its
ancestors) but does find a field or property parameter `name` of function type,
it is rewritten to a value call on the field access. A real method of the same
name still takes precedence, and a non-function field or a genuinely unknown name
still reports the unknown-method error.

## Implementation

- `src/lumen_check_expr.zig`: before the class-method resolution fails, the
  method-call handler looks up a same-named function-typed field or property
  parameter (walking the inheritance chain) and, when found and no method exists,
  rewrites the call to an `optional_call` on the field access.

## Verification

- `zig build` and `zig build test` green.
- A function-typed field (with and without arguments) and a function-typed
  constructor property parameter are callable via `this.name(...)`; a real method
  keeps precedence; unknown names and non-function fields still error.

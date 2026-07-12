# Spec 333 — Return inference for `this`-based and generic methods

## Goal

Infer an un-annotated method's return type when the return expression is built
from `this` — a computed expression, an indexed field, or a ternary — including
in generic classes:

```ts
class Stack<T> {
  items: T[] = [];
  top() {                                   // inferred: T | null
    return this.items.length > 0 ? this.items[this.items.length - 1] : null;
  }
}
class Point {
  constructor(public a: i32, public b: i32) {}
  sum() { return this.a + this.b; }         // inferred: i32
}
```

## Motivation

Method inference (specs 312, 318) only covered parameter-derived returns and the
`this.<field>` getter shortcut. Anything else built from `this`
(`this.items[0]`, `this.a + this.b`, a ternary over `this.items`) fell back to
the annotate-guidance, and generic methods could not infer at all because
specialization did not thread the program through — the documented spec 318 limit.

## Behavior

An un-annotated method now infers its return type by typing the return
expression with the parameters in scope **and `this` bound to the enclosing
class**, so any expression whose type the checker can resolve infers. Generic
specializations use the program captured at check entry, so their methods infer
too. Inference that still cannot resolve (e.g. a mutually-recursive
un-annotated pair) falls back to the annotate-guidance as before.

## Implementation

- `src/lumen_check.zig`: a `cur_program` field is set at check entry; the method
  inference in `fillClassTypes` uses `program orelse cur_program`, and binds
  `current_class` around the return-expression typing so `this` resolves.

## Verification

- `zig build` and `zig build test` green.
- `this.a + this.b`, `this.items[0]`, and a generic `top()` returning a ternary
  all infer and run; the `this.<field>` getter and parameter-derived inference
  are unchanged; a method calling a later un-annotated method still checks.

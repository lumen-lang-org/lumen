# Spec 318 — Return inference for generic-class getters

## Goal

A getter on a generic class should infer its return type from the returned field
without an explicit annotation:

```ts
class Box<T> {
  constructor(public value: T) {}
  get() { return this.value; }   // inferred: T (i32 for Box<i32>)
}
const b = new Box<i32>(5);
console.log(b.get());            // 5
```

## Motivation

Two issues blocked this. `specializeClass` cloned each generic method without
copying `infer_return` (and silently dropped `visibility`/`is_static`/
`accessor`/`is_async`), so a specialized method never attempted inference. And
the method-inference path only ran when a `program` was threaded through, which
generic specialization does not do.

## Behavior

- Generic method clones now preserve `infer_return` and the other member
  modifiers.
- `this.<field>` getter inference resolves against the class's own (substituted)
  fields directly, needing no expression-typing context, so it works for generic
  specializations too — `Box<i32>.get()` infers `i32`, `Box<string>.get()`
  infers `string`.

### Limit

A generic method whose un-annotated return depends on its parameters (not
`this.<field>`) is still inferred only when its specialized body is checked,
which happens after the main pass — a call before that point sees `void`. Annotate
such methods, or return a field.

## Implementation

- `src/lumen_check_generics.zig`: `specializeClass` copies `infer_return`,
  `visibility`, `is_static`, `accessor`, and `is_async` into each cloned method.
- `src/lumen_check.zig`: `fillClassTypes` runs `this.<field>` getter resolution
  before (and independently of) the `program`-dependent inference path.

## Verification

- `zig build` and `zig build test` green.
- `Box<i32>`/`Box<string>` getters infer and run; a generic class with a private
  field getter works; non-generic getter inference (spec 313) is unchanged.

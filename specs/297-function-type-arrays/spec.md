# Spec 297: arrays of function types

## Goal

```ts
let fns: ((x: i32) => i32)[] = [];
fns = fns.concat([(x: i32): i32 => x + 1]);
fns = fns.concat([(x: i32): i32 => x * 10]);
for (const f of fns) { total += f(5); }   // 6 + 50 = 56
```

Previously `((x: i32) => i32)[]` was a parse error (and the annotation
string couldn't distinguish an array of functions from a function returning
an array).

## Semantics

- When the parenthesized-type parser (spec 296) applies a `[]` suffix, it
  preserves the grouping parens, so an array of functions is encoded as
  `((i32)=>i32)[]` — distinct from `(i32)=>i32[]` (a function returning an
  array).
- `typeFromAnnotation` strips redundant outer grouping parens `(X)` -> X,
  but only when the leading `(` matches the final `)` (so a genuine function
  type, whose `(` closes mid-string, is left for the function-type handler).
  The element then resolves to a `func_type` and the `[]` suffix wraps it
  via `arrayOfAlloc` (spec 296) as a `nested_array`.

## Success Criteria

- **SC-001**: An array of function values compiles, accepts arrow elements
  via `concat`, iterates, and calls each element.
- **SC-002**: Function-type parameters, function-returning-function, and
  optional/nested/tuple arrays are unregressed; `zig build` and
  `zig build test` stay green.

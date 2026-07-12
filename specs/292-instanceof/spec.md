# Spec 292: instanceof

## Goal

```ts
const d: Dog = new Dog("rex");
d instanceof Dog       // true
d instanceof Animal    // true (Dog extends Animal)
a instanceof Dog       // false
if (d instanceof Animal) { ... }
```

Previously a parse error.

## Semantics

Classes are non-polymorphic in V1 (spec 270): a value's class is known
statically, so `x instanceof C` is a compile-time bool — `true` when `x`'s
class type is `C` or a subclass of `C`, else `false`. Emitted as a `true`/
`false` literal; the operand is still evaluated (and discarded) so its side
effects run. The right side must be a class name; anything else reports a
tailored error.

## Success Criteria

- **SC-001**: `instanceof` against the exact class, a superclass, and an
  unrelated class returns true/true/false; usable as an `if` condition.
- **SC-002**: `x instanceof NotAClass` reports the class-name error.
- **SC-003**: `zig build` and `zig build test` stay green.

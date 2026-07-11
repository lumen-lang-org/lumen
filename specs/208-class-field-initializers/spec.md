# Spec 208: class field initializers (`x: T = expr`)

## Goal

Allow a class instance field to declare a default value:

```ts
class Point {
  x: i32 = 1;
  y: i32 = 2;
  sum(): i32 { return this.x + this.y; }
}
new Point().sum();   // 3

class Stack {
  items: i32[] = [];
  size(): i32 { return this.items.length; }
}
```

Previously a field with an initializer (`x: i32 = 5`) was a syntax error; a field
could only be declared (`x: i32;`) and assigned in the constructor.

## Why additive, not breaking

Only makes previously-rejected programs compile. Plain field declarations and
constructors are unchanged.

## Semantics

An instance field initializer runs at construction, before the constructor
body, so a constructor may override it (`v: i32 = 100; constructor(v) { this.v =
v; }` yields the passed value). A class with field initializers but no
constructor gets a synthesized one that applies the defaults. Static field
initializers are not supported by this spec.

## Implementation

- Parser: a field followed by `= expr` records a `this.field = expr` assignment;
  after the class body, these are prepended to the constructor body (an empty
  constructor is synthesized when the class declares none).

## Requirements

- **FR-001**: `x: T = expr` gives every instance the default value.
- **FR-002**: A constructor body runs after the field initializers and may
  override them.
- **FR-003**: A class with field initializers needs no explicit constructor.
- **FR-004**: Plain field declarations and constructors are unchanged.

## Success Criteria

- **SC-001**: `class C { x: i32 = 5; }` — `new C().x` is `5`.
- **SC-002**: `count: i32 = 0; constructor() { this.count = 10; }` yields `10`;
  a second field keeps its default.
- **SC-003**: `items: i32[] = []` initializes an empty array field.
- **SC-004**: `v: i32 = 100; constructor(v) { this.v = v; }` — `new C(7).v` is
  `7`.
- **SC-005**: `zig build` and `zig build test` stay green.

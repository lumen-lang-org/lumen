# Spec 209: constructor parameter properties

## Goal

Support the TypeScript shorthand where a `public`/`private`/`protected`/
`readonly` modifier on a constructor parameter declares and assigns a field:

```ts
class Point {
  constructor(public x: i32, public y: i32) {}
  sum(): i32 { return this.x + this.y; }
}
new Point(3, 4).sum();   // 7
```

Previously a modifier on a constructor parameter was a syntax error; the field
had to be declared separately and assigned in the constructor body.

## Why additive, not breaking

Only makes previously-rejected programs compile. Plain constructor parameters
and explicit field declarations are unchanged.

## Semantics

A constructor parameter written `public p: T` (or `private`/`protected`/
`readonly`) declares an instance field `p` of type `T` and assigns `this.p = p`
at construction, before the rest of the constructor body — so the body may
override it. Parameter properties and ordinary parameters may be mixed.

## Implementation

- Parser: a visibility/readonly modifier before a parameter name sets
  `is_property` on the parameter. After the constructor is parsed, each property
  parameter adds a field and a `this.p = p` assignment prepended to the
  constructor body (reusing the field-initializer desugaring of spec 208).

## Requirements

- **FR-001**: `constructor(public p: T)` declares field `p` and assigns it from
  the argument.
- **FR-002**: `private`/`protected`/`readonly` modifiers are accepted the same
  way.
- **FR-003**: Parameter properties mix with ordinary parameters; the constructor
  body may override an assigned property.

## Success Criteria

- **SC-001**: `constructor(public x: i32, public y: i32) {}` — `new P(3,4).sum()`
  is `7`.
- **SC-002**: `constructor(readonly x, readonly y)` exposes both fields.
- **SC-003**: A body statement overriding a parameter property takes effect
  (`this.total = total * 2` → `new Acc(5).total` is `10`).
- **SC-004**: Plain constructors are unchanged.
- **SC-005**: `zig build` and `zig build test` stay green.

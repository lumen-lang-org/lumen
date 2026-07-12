# Spec 338 — `super()` with property parameters and constructor-less bases

## Goal

Make a derived-class constructor that uses parameter properties and calls
`super()` work, including when the base declares no constructor:

```ts
class Base {}
class Sub extends Base {
  constructor(public x: i32) { super(); }   // ok
}

class Shape { area(): number { return 0; } }
class Circle extends Shape {
  constructor(public r: number) { super(); }
  area(): number { return 3.14 * this.r * this.r; }
}
```

## Motivation

Two bugs made these common shapes fail:

1. A parameter property (`public x`) synthesizes a `this.x = x` initializer that
   the parser prepended to the whole constructor body — ahead of the user's
   `super(...)`. That both violated the "`this` only after `super()`" rule and
   tripped the missing-`super` check, reporting `E_MISSING_SUPER` even though
   `super()` was present.
2. When no ancestor declared a constructor, `super()` still emitted a call to a
   `__superctor_<Base>` helper that was never generated (helpers exist only for
   ancestors with a constructor), so the generated Zig failed to build.

## Behavior

- Parameter-property (and field) initializers are spliced in **after** a leading
  `super(...)`, so `super()` runs first and the missing-`super` check sees it.
- A `super()` whose ancestor chain has no constructor is a no-op (it already
  type-checks with zero arguments; it now emits nothing). `super(...)` still
  resolves to the nearest ancestor that does declare a constructor.

## Implementation

- `src/lumen_parser_decl.zig`: when prepending field initializers, a body that
  opens with a `super_ctor` statement keeps that statement first and inserts the
  initializers after it.
- `src/lumen_check_stmt.zig`: the `super_ctor` check nulls `sc.parent` when no
  ancestor has a constructor, so the emitter (which no-ops on a null parent)
  skips the nonexistent helper call.

## Verification

- `zig build` and `zig build test` green.
- A derived class with parameter properties and `super()` runs, over both a bare
  base (`class Base {}`), a method-only base, a base with a constructor, and a
  constructor on a grandparent reached through a constructor-less parent; plain
  inheritance without a constructor is unchanged.

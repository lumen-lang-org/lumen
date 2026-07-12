# Spec 352 — `super` calls through 3+ levels of inheritance

## Goal

Make `super.method()` resolve through more than two levels of inheritance:

```ts
class A { v(): i32 { return 1; } }
class B extends A { v(): i32 { return super.v() + 10; } }
class C extends B { v(): i32 { return super.v() + 100; } }   // 111
class D extends C { v(): i32 { return super.v() + 1000; } }  // 1111
```

## Motivation

A `super.m()` call is lowered by emitting, on the most-derived struct, a copy of
the ancestor method under `__super_<Owner>_m`. But the copy collector was not
transitive: for `C`, it emitted `__super_B_v` (a copy of `B.v`) whose body calls
`super.v()` → `__super_A_v`, but never emitted `__super_A_v` on `C`. The
generated Zig then failed with `no field or member function named '__super_A_v'`.

## Behavior

Emitting the copy of an ancestor method now also collects the `super` calls
inside that copied body, so every level of a `super` chain gets its copy on the
most-derived struct. The `seen` set keeps each copy unique and terminates the
recursion. Two-level `super` (the previously-working case) is unchanged.

## Implementation

- `src/lumen_emit_class.zig`: after emitting a `__super_<Owner>_<m>` copy,
  `collectSuperInExpr` recurses into that method's body (`emitSuperCopies`) to
  emit the deeper-level copies it references.

## Verification

- `zig build` and `zig build test` green.
- Three- and four-level `super.v()` chains compute correctly (111, 1111); a
  two-level chain still works.

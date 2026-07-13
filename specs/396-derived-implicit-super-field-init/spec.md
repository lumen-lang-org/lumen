# 396 — inherited field initializers run in a derived class (implicit super)

## Problem

A derived class whose constructor was synthesized purely from its own field
initializers never ran the base class's field initializers, leaving inherited
fields holding uninitialized garbage:

```ts
class A { x = 1; }
class B extends A { y = 2; }
const b = new B();
console.log(b.x + b.y); // -1431655764  (should be 3)
```

Field initializers (`x = 1`) desugar to `this.x = 1` prepended to the class's
constructor body, which also flips `has_ctor` to true. So `B` got a synthesized
constructor `{ this.y = 2 }` with **no** `super(...)` call. At emit time `__init`
runs only that body, so `A`'s `this.x = 1` never executed. (An *empty* derived
class worked, because with `has_ctor == false` the emitter reuses the nearest
ancestor constructor directly.)

## Approach

Mirror TypeScript's implicit `constructor(...args) { super(...args); }`. In
`checkClass` (`lumen_check_stmt.zig`), when a class:

- has a constructor body (`has_ctor`), and
- extends a parent, and
- the parent chain has a zero-argument constructor (its own or synthesized from
  field inits), and
- the body does not already open with `super(...)`, and
- the parent isn't parameterized (`parent_needs_super` still demands an explicit
  `super(...)` and errors otherwise),

splice an implicit no-arg `super()` at the front of the constructor body. It is
then checked and emitted like a written `super()`, routing through
`__superctor_<Parent>`, which itself emits the parent body (including *its* own
implicit `super()` for multi-level chains).

## Verification

- `class A{x=1} class B extends A{y=2}` → `b.x+b.y` = `3`.
- Three levels `A{x=1}/B{y=2}/C{z=3}` → `6`.
- Base with a 0-arg explicit ctor (`constructor(){this.x=5}`) + derived field
  init → `7`.
- Explicit `super()` path unchanged → `3`.
- Parameterized base still errors `E_MISSING_SUPER` when `super(...)` is omitted.
- Non-inheriting classes and inherited-method access unchanged.
- Full `zig build` + test suite green.

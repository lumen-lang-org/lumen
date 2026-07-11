# Spec 269: derived classes inherit the parent constructor

## Goal

```ts
class Animal {
  constructor(n: string) { this.name = n }
  speak(): string { ... }
}
class Dog extends Animal {          // no constructor of its own
  speak(): string { return this.name + " barks" }
}
const d: Dog = new Dog("rex")       // routes to Animal's ctor
```

Previously a derived class with no constructor whose parent takes
parameters was rejected with E_MISSING_SUPER — even though both emission
(ctor-owner resolution) and the `new`-site arity check already implement
inheritance. TS semantics: a missing constructor is
`constructor(...args) { super(...args) }`.

Also: `JSON.stringify({ ok: true })` on a bare object literal now says to
bind it to a named record type first, instead of a bare "type mismatch".

## Semantics

The checker requirement "parent has a parameterized ctor ⇒ derived must
call super" now applies only when the derived class declares its own
constructor. Classes with their own ctor still must call `super(...)`
first.

## Success Criteria

- **SC-001**: `new Dog("rex")` constructs through the inherited ctor and
  the override runs; wrong arity at the new site still errors.
- **SC-002**: A derived class WITH a ctor and no `super(...)` still fails.
- **SC-003**: `zig build` and `zig build test` stay green.

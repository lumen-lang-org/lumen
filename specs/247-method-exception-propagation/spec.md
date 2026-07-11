# Spec 247: exceptions propagate from class methods

## Goal

Completes spec 245 for classes — a throw inside a method is catchable by the
caller, through inheritance and `super` calls:

```ts
class Account {
  withdraw(amount: i32): i32 {
    if (amount > this.balance) throw new Error("insufficient funds")
    ...
  }
}
try { a.withdraw(500) } catch (e) { ... }   // ← now catches
```

## Semantics

- The throwing-set fixpoint (spec 245) also visits class methods. Method
  keys are name-based across all classes (`m:<name>`), so emission, call
  sites, inherited flattened copies, and `__super_` copies always agree; a
  same-named method that never throws just carries an error union that
  never errors.
- Throwing instance methods, static methods, and super copies emit as
  `error{LumenThrow}!T`; call sites (`obj.m()`, `Class.m()`, `super.m()`)
  unwrap by the same context rules as function calls: route to the enclosing
  try's catch, `try`-forward inside a throwing function/method, else panic
  with the thrown message (pretty uncaught rendering).
- Stack frames through a `super` call are labeled with the defining class
  (`at Base.check`), not the derived receiver.
- Getters/setters, constructors, and async methods keep panic semantics.

## Success Criteria

- **SC-001**: A method throw is caught by the caller's try/catch; the object
  keeps working after.
- **SC-002**: An overriding method's throw and its `super` call's throw are
  caught separately; the uncaught trace shows `Base.check` beneath
  `Derived.check`.
- **SC-003**: `zig build` and `zig build test` stay green.

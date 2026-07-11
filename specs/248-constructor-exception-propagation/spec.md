# Spec 248: exceptions propagate from constructors

## Goal

Validation in a constructor is catchable — the last propagation gap from
specs 245/247:

```ts
class Conn {
  constructor(port: i32) {
    if (port < 1) throw new Error("bad port")
    ...
  }
}
try { const c: Conn = new Conn(0) } catch (e) { ... }   // ← now catches
```

## Semantics

- The fixpoint pass keys constructors per class (`c:<class>`): a class whose
  resolved constructor chain (own body, or the nearest ancestor's when the
  class declares none — including `super(...)` forwarding and calls to
  throwing functions/methods) can throw emits `__init` as an error union.
- `new C(...)` sites unwrap by the usual context rules (route to the
  enclosing try, `try`-forward, or panic with the thrown message).
- `super(...)` lowers through `__superctor_<Owner>` helpers, which carry the
  same error union when the owner's chain throws.

## Success Criteria

- **SC-001**: A direct constructor throw is caught by try/catch around `new`.
- **SC-002**: With inheritance, both the parent's throw (via `super(...)`)
  and the child's own throw are caught; a valid construction still works;
  an uncaught constructor throw reports the throw site.
- **SC-003**: `zig build` and `zig build test` stay green.

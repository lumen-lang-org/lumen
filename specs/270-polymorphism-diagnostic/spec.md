# Spec 270: subclass-in-superclass-slot diagnostic

## Goal

```text
error: class values are not polymorphic — a `Animal` slot cannot hold a
`Dog`; declare it as `Dog`, or model the variants as a discriminated union
```

Previously assigning a subclass value to a superclass-typed slot reported a
bare "type mismatch: expected `Animal`, got `Dog`" with no explanation of
why an apparently-valid TS upcast is rejected (V1 classes compile to flat
structs — no vtables, no shared layout).

## Semantics

`failTypeMismatch` recognizes the expected/actual pair being class types in
a subclass relation and swaps in the explanation + alternatives. All other
mismatches unchanged.

## Success Criteria

- **SC-001**: `const a: A = new B()` (B extends A) reports the message.
- **SC-002**: `zig build` and `zig build test` stay green.

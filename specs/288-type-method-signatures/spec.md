# Spec 288: method signatures in `type` object bodies

## Goal

```ts
type Runnable = { run(x: i32): i32 };
class Doubler implements Runnable {
  run(x: i32): i32 { return x * 2 }
}
```

Spec 254 added method-signature shorthand (`name(params): R`) to
`interface` bodies but not to `type X = { ... }` bodies, so the `type`
form was still a parse error. This brings them to parity.

## Semantics

The `(params): R` member shorthand is parsed by a shared
`parseMethodSigAnnotation` helper used by both `interface` and `type`
object bodies, recording a function-typed member `(T,...)=>R`. A class
`implements` such a type exactly as it does an interface, and the
missing-member check applies.

## Success Criteria

- **SC-001**: A `type` with a method member is implemented by a class and
  the method runs.
- **SC-002**: A class missing the method reports the missing-member error.
- **SC-003**: `zig build` and `zig build test` stay green.

# Spec 284: enum-container guidance

## Goal

```text
error: enum containers are not supported yet — `Status[]` can be modeled as
a string-literal union type (`type S = "a" | "b"`) or the backing `i32[]`
```

Previously `const xs: Status[] = [Status.Active]` reported the
absurd-looking "expected `Status`, got `Status`" (the annotation resolved
to an unknown named type shadowing the enum's name).

## Success Criteria

- **SC-001**: The probe reports the guidance; scalar enum use (switch,
  compare, pass) is unchanged.
- **SC-002**: `zig build` and `zig build test` stay green.

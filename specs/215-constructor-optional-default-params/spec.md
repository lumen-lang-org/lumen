# Spec 215: optional and default constructor parameters

## Goal

Let a constructor honor optional (`x?`) and default (`x = e`) parameters, so a
`new` call may omit trailing arguments:

```ts
class C {
  constructor(public x: i32, public y?: i32) {}
}
new C(5);      // y omitted -> null
new C(5, 9);   // y = 9

class D {
  v: i32;
  constructor(a: i32, b: i32 = 10) { this.v = a + b; }
}
new D(5).v;    // 15
```

Previously a `new` call required exactly as many arguments as the constructor
declared (`E_ARG_COUNT`), even when trailing parameters were optional or had
defaults.

## Why additive, not breaking

Only makes previously-rejected `new` calls compile. A constructor with all
required parameters, and its exact-arity calls, are unchanged.

## Semantics

A constructor call is checked with the same argument logic as a function call
(spec 189): optional parameters may be omitted (filled with `null`), default
parameters use their default when omitted, and too few required arguments still
error. This applies to parameter properties (`public y?: i32`) as well.

## Implementation

- Checker: the `new` argument check routes through the shared `checkCallArgs`
  instead of an exact-count comparison, so it fills defaults / nulls and
  validates types uniformly.

## Requirements

- **FR-001**: A `new` call may omit an optional (`x?`) or defaulted constructor
  parameter.
- **FR-002**: Too few required arguments still reports `E_ARG_COUNT`.
- **FR-003**: Full-arity constructor calls are unchanged.

## Success Criteria

- **SC-001**: `new C(5)` for `constructor(public x, public y?)` — `y` is null;
  `new C(5, 9)` sets it.
- **SC-002**: `constructor(a, b = 10)` — `new D(5).v` is `15`, `new D(5,20).v` is
  `25`.
- **SC-003**: `new C(3)` for two required parameters reports `E_ARG_COUNT`.
- **SC-004**: `zig build` and `zig build test` stay green.

# Spec 254: interface method signatures, `?? null`, missing-member naming

## Goal

Standard TS interface method shorthand parses and checks:

```ts
interface Shape { area(): f64 }
class Circle implements Shape {
  area(): f64 { return 3.14159 * this.r * this.r }
}
```

Previously it was a parse error ("expected ':', found '('") — only
field-style members were accepted. Also:

- `find(...) ?? null` (normalizing a `T | null` with `?? null`) type-checks
  as `T | null` instead of "expected `T`, got `null`".
- A class missing an interface member reports
  `class 'Triangle' is missing member 'area' required by interface `Shape``
  instead of the bare code.

## Semantics

- `name(params): R` inside `interface`/`type` bodies records a
  function-typed member `(T,...)=>R` (return defaults to `void`); the
  existing implements check accepts a class method for it.
- `expr ?? null` keeps the left side's optional type (JS normalization
  idiom); other coalesce rules unchanged.

## Success Criteria

- **SC-001**: The Shape/Circle program runs; a class missing the method
  fails with the named message.
- **SC-002**: `?? null` compiles and runs with the value flowing through.
- **SC-003**: `zig build` and `zig build test` stay green.

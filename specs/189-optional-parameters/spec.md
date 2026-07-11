# Spec 189: optional parameters (`x?: T`)

## Goal

Allow an optional parameter to be omitted at the call site:

```ts
function greet(name: string, greeting?: string): string {
  return (greeting ?? "Hello") + ", " + name;
}
greet("A");         // "Hello, A"
greet("B", "Hi");   // "Hi, B"
```

Previously `x?: T` parsed (the parameter's type became `T | null`) but calling
without the argument reported `E_ARG_COUNT` — the parameter was treated as
required.

## Why additive, not breaking

Only makes previously-rejected calls compile. A required parameter of an
optional type (`a: T | null`, which must still be passed) is unchanged, as are
default parameters (`y: T = expr`).

## Semantics

`x?: T` is an omittable parameter of type `T | null`. When a call omits it, it is
filled with `null`. This is distinct from `a: T | null`, a *required* parameter
of optional type that must be passed explicitly — the parser records the
`?`-before-colon form as `is_optional`, so the two are told apart even though
both carry an optional annotation. A required parameter after an optional one is
still rejected (`E_REQUIRED_AFTER_OPTIONAL`).

## Implementation

- Parser: records `is_optional` on a parameter written `name?: T` (detected
  before the `?` is folded into the annotation).
- Checker: an optional parameter does not count toward the required-argument
  minimum and is disallowed before a required one; an omitted optional argument
  is filled with a `null` literal.

## Requirements

- **FR-001**: An `x?: T` parameter may be omitted (filled with `null`) or passed.
- **FR-002**: Multiple trailing optional parameters may each be omitted.
- **FR-003**: A required parameter of optional type (`a: T | null`) still must be
  passed; a required parameter after an optional one is rejected.

## Success Criteria

- **SC-001**: `g(5)` and `g(5, 3)` for `g(x: i32, y?: i32)` both compile
  (`y ?? 0` yields `0` when omitted).
- **SC-002**: `f(1)`, `f(1,2)`, `f(1,2,3)` for `f(a, b?, c?)` all work.
- **SC-003**: `greet("A")` -> `Hello, A`; `greet("B","Hi")` -> `Hi, B`.
- **SC-004**: `bad(a?: i32, b: i32)` reports `E_REQUIRED_AFTER_OPTIONAL`.
- **SC-005**: `zig build` and `zig build test` stay green.

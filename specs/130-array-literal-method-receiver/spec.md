# Spec 130: Array methods on array literals

## Goal

Allow calling an array instance method directly on an array literal, e.g.
`[1,2,3].includes(2)`, `[1,2,3].concat([4,5])`, `["a","b"].indexOf("b")`.
Previously the type checker accepted these but codegen produced an anonymous
tuple (`&.{...}`) for the receiver, which is not a runtime slice, so the
generated Zig failed to build.

## Why additive, not breaking

Only makes previously-broken programs compile. A method on an array *variable*
already emitted a real slice and is unchanged; a literal receiver is now wrapped
in an explicit `[]const T` cast so it becomes the same slice type.

## API

Not a library API. Every array instance method (`includes`, `indexOf`,
`lastIndexOf`, `at`, `slice`, `join`, `reverse`, `concat`, `map`, `filter`,
`reduce`, ...) accepts an array-literal receiver. `concat`'s array-literal
argument is coerced the same way.

## Requirements

- **FR-001**: `[<items>].method(...)` compiles and runs identically to binding
  the literal to a variable first and calling the method on the variable.
- **FR-002**: `concat` accepts an array-literal argument
  (`[1,2].concat([3,4])`).
- **FR-003**: Non-literal receivers (variables, chained method results) are
  unaffected.

### Out of scope
Property/index access on a bare literal (`[1,2,3].length`, `[1,2,3][0]`) still
requires binding to a variable — those go through the field/index path, not the
method-call path.

## Success Criteria

- **SC-001**: `[1,2,3].includes(2)` -> `true`; `[1,2,3].includes(5)` -> `false`;
  `[1,2,3].indexOf(3)` -> `2`; `[3,1,2].at(-1)` -> `2`;
  `[1,2,3].concat([4,5]).join(",")` -> `1,2,3,4,5`;
  `[1,2,3].reverse().join(",")` -> `3,2,1`.
- **SC-002**: `zig build` and `zig build test` stay green.

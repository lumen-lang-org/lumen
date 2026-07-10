# Spec 160: multiple arguments for console.log as an expression

## Goal

Extend the console.log-as-expression form (spec 151) to accept multiple
arguments, so index-and-value logging inside an arrow body works:

```ts
arr.forEach((x, i) => console.log(i, x));
arr.forEach(x => console.log("value:", x));
```

Previously the expression form accepted exactly one argument; extra arguments
reported `E_ARG_COUNT` (the statement form already supported many, spec 157).

## Why additive, not breaking

Only makes previously-rejected programs compile. Single-argument
console.log-as-expression and the statement form are unchanged.

## Semantics

`console.log(a, b, ...)` as an expression prints its arguments space-separated
with a trailing newline and evaluates to `void`, matching the statement form.
Each argument is coerced to a string (via the runtime `String()` conversion) so
any mix of printable types formats uniformly.

## Requirements

- **FR-001**: `console.log(a, b, ...)` is a valid void expression for one or more
  printable arguments.
- **FR-002**: Arguments print space-separated, matching the statement form.
- **FR-003**: The statement form is unchanged.

## Success Criteria

- **SC-001**: `arr.forEach((x, i) => console.log(i, x))` prints `index value`
  per element.
- **SC-002**: `arr.forEach(x => console.log("value:", x))` prints
  `value: <x>` per element.
- **SC-003**: `console.log("stmt", "multi", 3)` (statement) still works.
- **SC-004**: `zig build` and `zig build test` stay green.

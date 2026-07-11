# Spec 279: assignment mismatches and number-method errors name types

## Goal

```text
main.ts:2:1: error: type mismatch: expected `i32`, got `string`   # y = "s"
main.ts:2:1: error: `i32` has no method 'toUpperCase'
```

Previously both were a bare "type mismatch". Plain assignments now also
route through `ensureAssignable`, so numeric promotion applies:
`f = 3` onto an `f64` binding works (specs 255/256/258 coverage extended to
`=`).

## Success Criteria

- **SC-001**: `y = "string"` on an i32 binding reports expected/got; a
  wrong method on a number reports the receiver type and method.
- **SC-002**: `f2 = 3` on an f64 binding compiles and runs.
- **SC-003**: `zig build` and `zig build test` stay green.

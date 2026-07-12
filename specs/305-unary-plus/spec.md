# Spec 305: unary plus

## Goal

```ts
const n: i32 = +5;
const f: f64 = +3.14;
console.log(+n + +x);
```

Previously `+x` was a syntax error.

## Semantics

Unary `+` on a numeric operand is the identity (as in JS for numbers); it
parses and returns the operand directly. Applying it to a non-numeric value
surfaces through that value's own type downstream.

## Success Criteria

- **SC-001**: `+5`, `+3.14`, and `+x` (on a numeric binding) evaluate to the
  operand.
- **SC-002**: `zig build` and `zig build test` stay green.

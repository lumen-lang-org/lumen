# Spec 202: untyped arrow argument to a function-typed parameter

## Goal

Infer an untyped arrow's parameter types from the function-typed parameter it is
passed to:

```ts
function apply(f: (x: i32) => i32, v: i32): i32 { return f(v); }
apply(x => x * 2, 5);   // 10  — `x` inferred as i32
```

Previously an untyped arrow argument reported `E_TYPE_MISMATCH`; only a typed
arrow (`(x: i32) => ...`), a named function, or an arrow bound to a variable
worked.

## Why additive, not breaking

Only makes previously-rejected calls compile. Typed arrows, named function
values, and arrow variables passed to function parameters are unchanged
(their representation already worked — this only closes the inference gap).

## Semantics

When an arrow literal is passed as an argument whose parameter type is a
function type, the parameter's declared parameter types are supplied as
contextual hints for the arrow's untyped parameters (the same mechanism as a
method callback like `map`/`filter`). The arrow's resulting type must match the
parameter's function type.

## Requirements

- **FR-001**: `apply(x => …, …)` infers the arrow's parameters from the
  function-typed parameter.
- **FR-002**: Multi-parameter arrows (`(a, b) => …`) infer each parameter.
- **FR-003**: Typed arrows, named functions, and arrow variables are unchanged.

## Success Criteria

- **SC-001**: `apply(x => x * 2, 5)` for `apply(f: (x: i32) => i32, v: i32)` ->
  `10`.
- **SC-002**: `combine((a, b) => a + b, 3, 4)` -> `7`.
- **SC-003**: `transform(s => s.toUpperCase(), "hi")` -> `HI`.
- **SC-004**: Typed arrow / named function arguments still work.
- **SC-005**: `zig build` and `zig build test` stay green.

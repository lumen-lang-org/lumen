# Spec 150: typeof operator

## Goal

Support the `typeof` prefix operator, yielding a type-name string like
JavaScript:

```ts
typeof 5          // "number"
typeof "hello"    // "string"
typeof true       // "boolean"
typeof [1,2,3]    // "object"
typeof x === "number"
```

Previously `typeof` was a syntax error.

## Why additive, not breaking

Purely additive — a new prefix operator. Nothing existing changes.

## Semantics

Because Lumen is statically typed, `typeof x` resolves at compile time to a
constant string derived from the operand's static type:

| static type                         | result       |
| ----------------------------------- | ------------ |
| `i32` / `i64` / `f64` / int literal | `"number"`   |
| `string`                            | `"string"`   |
| `bool`                              | `"boolean"`  |
| a function value                    | `"function"` |
| an optional / `null`                | `"undefined"`|
| anything else (arrays, objects, …)  | `"object"`   |

The operand is still evaluated (and its result discarded) so any side effects
run and the operand's bindings count as used, but the produced value is the
compile-time constant string.

## Requirements

- **FR-001**: `typeof <expr>` parses as a prefix operator and yields a `string`.
- **FR-002**: The string reflects the operand's static type per the table above.
- **FR-003**: The operand is evaluated for its side effects.

## Success Criteria

- **SC-001**: `typeof 5` -> `number`; `typeof "hello"` -> `string`;
  `typeof true` -> `boolean`; `typeof 3.14` -> `number`;
  `typeof [1,2,3]` -> `object`.
- **SC-002**: `typeof x === "number"` (for an `i32` `x`) -> `true`;
  `typeof "s" === "string"` -> `true`.
- **SC-003**: `zig build` and `zig build test` stay green.

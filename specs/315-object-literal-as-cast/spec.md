# Spec 315 — Object/array literals with `as T`

## Goal

Accept an object or array literal written directly with an `as T` assertion:

```ts
type P = { x: i32 };
const p = { x: 1 } as P;                 // p: P
console.log(JSON.stringify({ x: 1 } as P));
```

## Motivation

A bare object literal cannot be typed on its own — it needs a target record type
— so `{ x: 1 } as P` reported `cannot infer variable type` (and `unknown field
type` in argument position). `as T` already carries the target, so the literal
should type against it, exactly as `satisfies T` does.

## Behavior

When the operand of an `as T` cast cannot be typed standalone (an object literal,
an empty array), the literal is checked structurally against `T` and the cast
takes `T` as its type. A field of the wrong type is still rejected:
`{ x: "no" } as P` reports `expected `i32`, got `string``.

Casts of already-typed expressions are unchanged, as is `as const` (spec 307).

## Implementation

- `src/lumen_check_expr.zig`: in the `.cast` handler, when `exprType` of the
  operand is null, fall back to `ensureAssignable(target, operand)` and return
  the target type.

## Verification

- `zig build` and `zig build test` green.
- `{ x: 1 } as P` types as `P` in `const`, argument, and `JSON.stringify`
  positions; a wrong-typed field errors; other casts unchanged.

# Spec 311 — Return-type inference for block-body arrows

## Goal

Extend return-type inference (spec 310) to block-body arrow functions:

```ts
const double = (a: i32) => { return a * 2; };   // inferred: i32
const sign = (n: i32) => { if (n > 0) return "p"; return "n"; };  // string
```

## Motivation

Expression-body arrows (`(a) => a * 2`) already inferred their return type, but
a block-body arrow without a return annotation was treated as `void`, so a
value `return` was rejected. This closes that inconsistency.

## Behavior

- A block-body arrow with no return annotation infers its return type from the
  first value `return <expr>`; the arrow's parameters are in scope, so the
  common case (a return built from the parameters) infers directly.
- All paths must return when the inferred type is non-`void` (`E_MISSING_RETURN`
  otherwise), matching annotated block arrows.
- A body that returns no value stays `void`.
- When the first return uses a local binding declared inside the body (not yet
  in scope at inference time), the arrow reports the same actionable guidance as
  named functions: add an explicit `: T` return annotation.

## Implementation

- `src/lumen_check_expr.zig`: the no-annotation block-arrow branch infers the
  return type via `firstReturnExpr` + `exprType`, sets `current_return_type` for
  the body check, enforces all-paths-return, and flags an un-inferable arrow so
  the `return` check emits the annotate-guidance. The inferred type flows to
  emit through the existing `arrow.checked_return_type`.

## Verification

- `zig build` and `zig build test` green.
- Block-body arrows returning parameter-derived values infer and run; void
  arrows unchanged; expression-body arrows unchanged; all-paths-return is
  enforced; a return of a body-local binding gets the guidance message.

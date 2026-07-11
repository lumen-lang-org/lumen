# Spec 182: `Math.min` / `Math.max` with a single argument

## Goal

Accept a single argument to `Math.min` / `Math.max`, which JS returns verbatim:

```ts
Math.min(5);    // 5
Math.max(3.5);  // 3.5
```

Previously a single numeric argument reported `E_ARG_COUNT` (two or more were
required), even though the spread form `Math.min(...arr)` and the multi-argument
form already worked.

## Why additive, not breaking

Only makes previously-rejected programs compile. The zero-argument call still
errors, and the spread and multi-argument forms are unchanged.

## Semantics

`Math.min(x)` / `Math.max(x)` for a single numeric `x` is `x` (its type is the
argument's numeric type). The existing left-fold emit already produces just the
value for one argument, so only the checker's arity guard needed relaxing.

## Requirements

- **FR-001**: `Math.min(x)` / `Math.max(x)` type-check for a single numeric `x`
  and return `x`.
- **FR-002**: Zero arguments still error; multi-argument and spread forms are
  unchanged.

## Success Criteria

- **SC-001**: `Math.min(5)` -> `5`; `Math.max(42)` -> `42`; `Math.min(3.5)` -> `3.5`.
- **SC-002**: `Math.min(3,1,2)` -> `1`; `Math.max(...[3,7,2])` -> `7`.
- **SC-003**: `Math.min()` still reports `E_ARG_COUNT`.
- **SC-004**: `zig build` and `zig build test` stay green.

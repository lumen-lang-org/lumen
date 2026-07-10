# Spec 131: Inferred arrow-function parameters

## Goal

Allow array higher-order method callbacks to be written with untyped parameters,
the way they are in idiomatic TypeScript/JavaScript:

```ts
a.map(v => v * 10)
a.filter(v => v > 2)
a.reduce((acc, v) => acc + v, 0)
a.toSorted((x, y) => x - y)
a.map((v, i) => v + i)
```

Previously every arrow parameter required an explicit type annotation
(`(v: i32) => ...`); a bare `v => ...` was a syntax error and `(v) => ...` was
rejected for the missing annotation.

## Why additive, not breaking

Purely additive. Typed parameters still work exactly as before; only the
previously-rejected untyped forms now compile. An untyped parameter with no
inference context (e.g. a standalone `const f = v => v + 1;`) still reports
`E_TYPE_MISMATCH`, because there is no signature to infer from.

## Design

- **Parser**: `parseArrow` makes the `: T` annotation optional (empty string
  means "infer"). A bare single-parameter arrow `v => expr` (no parentheses) is
  recognized in primary-expression position.
- **Checker**: a call that knows the callback signature it expects publishes
  positional parameter hints (`arrow_param_hint`) before checking the callback
  argument. The arrow consumes them: each untyped parameter takes the hint at
  its position; the hint is cleared immediately so a nested arrow does not reuse
  it. Array methods supply hints — `map`/`filter`/`find`/`some`/`every`/
  `forEach`/`findIndex`/`findLast*` use `[elem, i32]`, `reduce`/`reduceRight`
  use `[acc, elem, i32]`, `sort`/`toSorted` use `[elem, elem]`.

## Requirements

- **FR-001**: `v => expr` and `(v) => expr` are accepted as array-method
  callbacks; the parameter type is inferred from the method's callback
  signature.
- **FR-002**: A trailing index parameter (`(v, i) => ...`) infers to `i32`.
- **FR-003**: Explicitly typed parameters continue to type-check exactly as
  before.
- **FR-004**: An untyped parameter with no inference context reports
  `E_TYPE_MISMATCH`.

### Out of scope
Statement-body arrows (`v => { ... }`) remain unsupported — only expression
bodies. That is orthogonal to parameter inference.

## Success Criteria

- **SC-001**: `[1,2,3,4].map(v => v * 10).join(",")` -> `10,20,30,40`;
  `a.filter(v => v > 2)`, `a.reduce((acc, v) => acc + v, 0)` -> `10`,
  `a.find(v => v > 2)` -> `3`, `a.findIndex(v => v == 3)` -> `2`,
  `a.map((v, i) => v + i)` -> `1,3,5,7`, `a.toSorted((x, y) => x - y)` sorts
  ascending.
- **SC-002**: `a.map((v: i32) => v + 1)` still compiles.
- **SC-003**: `const f = v => v + 1;` reports `E_TYPE_MISMATCH`.
- **SC-004**: `zig build` and `zig build test` stay green.

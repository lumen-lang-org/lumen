# Spec 138: Math constants as properties

## Goal

Let the Math constants be read as properties, the way they are in JavaScript,
instead of only as zero-argument calls:

```ts
Math.PI        // 3.141592653589793   (was: undefined variable 'Math')
Math.PI * r * r
```

Previously only the call form `Math.PI()` was accepted.

## Why additive, not breaking

Purely additive. `Math.PI()` (and the other constant call forms) still work; the
property form is now also accepted. A local binding named `Math` still shadows
the namespace, so user code is unaffected.

## API

Read as `number` properties: `Math.PI`, `Math.E`, `Math.LN2`, `Math.LN10`,
`Math.LOG2E`, `Math.LOG10E`, `Math.SQRT2`, `Math.SQRT1_2`.

## Requirements

- **FR-001**: Each Math constant is readable as a property yielding the same f64
  value as its call form.
- **FR-002**: The existing `Math.PI()` call form is unchanged.
- **FR-003**: A local `Math` binding shadows the namespace (the property form is
  only recognized when `Math` is not a binding).

## Success Criteria

- **SC-001**: `Math.PI` -> `3.141592653589793`; `Math.E` -> `2.718281828459045`;
  `Math.SQRT2` -> `1.4142135623730951`.
- **SC-002**: `Math.PI * 2.0` -> `6.283185307179586`;
  `Math.round(Math.PI)` -> `3`.
- **SC-003**: `Math.PI()` still returns `3.141592653589793`.
- **SC-004**: `zig build` and `zig build test` stay green.

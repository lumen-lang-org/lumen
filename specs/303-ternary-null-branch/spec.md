# Spec 303: `cond ? value : null` yields an optional

## Goal

The common "value or null" ternary works:

```ts
function first<T>(xs: T[]): T | null {
  return xs.length > 0 ? xs[0] : null;   // T | null
}
const label: string | null = ok ? "yes" : null;
```

Previously the branches were unified strictly (`T` vs `null`) and reported
"type mismatch: expected `i32`, got `null`".

## Semantics

When a ternary's two branches don't have the same type but one is a bare
`null` (or an optional) and the other is a value type `T`, the ternary
types as `T | null`. Emission casts both branches to `?T` so Zig's
peer-type resolution keeps the expression optional (a `result_type` field
on the ternary records this). Works for generic element types (`xs[0]`
where `T` is the specialized parameter). Same-type branches and the
existing empty-array / object-literal branch borrowing are unchanged.

## Success Criteria

- **SC-001**: `cond ? xs[0] : null` compiles and returns the value or null;
  `cond ? "s" : null` yields `string | null`.
- **SC-002**: The generic `first<T>` form works and specializes.
- **SC-003**: `zig build` and `zig build test` stay green.

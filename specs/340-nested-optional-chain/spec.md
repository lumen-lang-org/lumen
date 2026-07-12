# Spec 340 — Deeply nested optional chains

## Goal

Chain optional access more than two levels deep when intermediate fields are
optional:

```ts
type C = { d?: i32 };
type B = { c?: C };
type A = { b?: B };
const a: A = {};
console.log(a.b?.c?.d ?? -1);       // -1
```

## Motivation

A two-level chain (`a.b?.c`) worked, but a third level (`a.b?.c?.d`) reported a
bare `type mismatch`. The middle access `a.b?.c` yields an optional `C`, and the
next `?.d` on an *already-optional* field produced a double optional
`(i32 | null) | null`, which then failed to line up with `??`.

## Behavior

An optional chain whose next field is itself optional flattens to a single
optional (`i32 | null`), so arbitrarily deep chains type and evaluate correctly:
the whole chain short-circuits to `null` at the first null link, and otherwise
reads the final field's value.

## Implementation

- `src/lumen_check_expr.zig`: in the optional-chain field handler, when the
  resolved field type is already optional, return it directly (rather than
  wrapping it again) and record the unwrapped element type for the emit's
  `@as(?T, __oc.field)` coercion.

## Verification

- `zig build` and `zig build test` green.
- A three-level chain resolves its value when the whole path is present and
  short-circuits to the `??` fallback when any link (including the final optional
  field) is null; two-level chains are unchanged.

# Spec 349 — Optional method calls and optional class-field access

## Goal

Support `a?.m(args)` (optional method call) and `instance?.field` (optional
chaining on a class instance):

```ts
const c: C | null = maybe();
console.log(c?.greet() ?? "none");        // method call
console.log(c?.name ?? "none");           // class field

type O = { inner: I | null };
console.log(o.inner?.getName() ?? "none"); // function-typed field on optional
```

## Motivation

Optional method calls were rejected outright (`a?.m()` is not supported), and
optional chaining resolved record fields but not class-instance fields — both
are pervasive TypeScript null-safety idioms.

## Behavior

- `a?.m(args)` where the receiver `a` is side-effect free desugars to
  `a != null ? a.m(args) : null`; the ternary's then-branch narrows away the
  optional, so the call resolves normally. The result is `ReturnType(m) | null`.
  A receiver with side effects (e.g. `f()?.m()`) still reports the
  unsupported-optional-call message (evaluating it twice would be wrong).
- `instance?.field` on an optional class instance yields `FieldType | null`,
  short-circuiting to `null` when the receiver is null; visibility is enforced.
- Record-field, builtin (`?.length`/`?.size`), and index optional chaining
  (specs 324, 340) are unchanged.

## Implementation

- `src/lumen_check_expr.zig`:
  - The optional `method_call` handler desugars to a narrowing ternary when the
    receiver is pure (`isPureReceiver`); the guard uses a deep copy of the
    receiver (`clonePure`) so narrowing's per-node unwrap flag is not shared
    between the guard and the call.
  - The optional-chain `field` handler resolves a class-instance field (in
    addition to records and builtins).

## Verification

- `zig build` and `zig build test` green.
- Optional method calls (with and without arguments, on class instances and
  function-typed record fields) and optional class-field access short-circuit on
  null and evaluate on a present receiver; an impure optional-call receiver still
  reports guidance; record/builtin optional chaining is unchanged.

# Spec 275: Array.isArray

## Goal

```ts
Array.isArray(items)    // true for any array-typed value
Array.isArray("nope")   // false
```

Previously E_UNSUPPORTED_STD.

## Semantics

Types are static, so the verdict is computed at compile time and emitted as
a bool literal; the argument expression is still evaluated. Matches JS
observable behavior for every typeable value.

## Success Criteria

- **SC-001**: Arrays report true; strings/numbers report false.
- **SC-002**: `zig build` and `zig build test` stay green.

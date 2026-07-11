# Spec 271: discarded-transform warning

## Goal

```text
main.ts:6:1: warning: result of '.sort()' is discarded — it returns a new
value (the receiver is immutable); assign it: `x = x.sort(...)`
```

`names.sort()` as a statement is a JS habit that silently does nothing in
Lumen (arrays and strings are immutable; transforms return new values).

## Semantics

An expression statement whose value is a non-void array/string transform
method (sort, map, filter, slice, concat, toUpperCase, ...) warns that the
result is dropped. Mutating container methods (`map.set`, `set.add`),
console calls, and void methods are unaffected.

## Success Criteria

- **SC-001**: `names.sort()` as a statement warns; `a = a.sort()` doesn't.
- **SC-002**: `m.set(...)` produces no warning.
- **SC-003**: `zig build` and `zig build test` stay green.

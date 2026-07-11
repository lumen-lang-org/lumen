# Spec 218: readable diagnostics with type detail

## Goal

Replace raw `E_*` code output with human-readable messages, and carry the
expected/actual types on type mismatches:

```text
g.ts:1:7: error: type mismatch: expected `i32`, got `string`
  1 | const x: i32 = "hello"
    |       ^
```

Previously the same failure printed only `error: E_TYPE_MISMATCH`.

## What changed

- **`types.tsName`**: a user-facing TypeScript-syntax renderer for every type
  (`string`, `i32[]`, `Map<string, i32>`, `(i32) => boolean`, `T | null`,
  tuples). Diagnostics never leak internal Zig spellings.
- **`Checker.failTypeMismatch(expected, actual)`**: formats
  ``type mismatch: expected `X`, got `Y```, used by every
  `ensureAssignable` mismatch path plus the return-statement and ternary
  branch checks — so declarations, call arguments, array elements, record
  fields, Map/Set values, and returns all report both types.
- **Message preservation**: 52 call sites used to `catch` an
  `ensureAssignable` error and overwrite the recorded message with a generic
  `E_TYPE_MISMATCH`; they now propagate the detailed inner message.
- **`humanizeDiag`** in the CLI: every remaining raw `E_*` code renders as a
  plain-English sentence with the code kept in brackets for grep-ability, e.g.
  `not all code paths return a value [E_MISSING_RETURN]`,
  `record fields are immutable; build a new object instead
  [E_DYNAMIC_PROPERTY_WRITE]`.

## Why additive, not breaking

Diagnostics only; no language-semantics change. The `E_*` codes remain
visible in brackets so existing tooling that greps for them keeps working.

## Success Criteria

- **SC-001**: `const x: i32 = "hello"` reports expected `i32`, got `string`.
- **SC-002**: A mismatched call argument, array element, record field, Map
  value, ternary branch, and return value each report both types.
- **SC-003**: Every raw code (`E_ARG_COUNT`, `E_MISSING_RETURN`,
  `E_CONST_ASSIGNMENT`, ...) renders as a sentence with the code bracketed.
- **SC-004**: `zig build` and `zig build test` stay green.

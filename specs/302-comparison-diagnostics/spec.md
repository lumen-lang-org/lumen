# Spec 302: comparison operand diagnostics name the types

## Goal

```text
main.ts:3:1: error: cannot compare `string` and `i32` — both sides of `==`
must be the same type
main.ts:2:1: error: `<` needs numeric operands, got `boolean`
```

Both were previously a bare `E_TYPE_MISMATCH`.

## Semantics

A comparison between differently-typed operands names both types and the
operator; a relational comparison (`< > <= >=`) on non-numeric operands
names the operator and the operand type. String relational comparison
(lexicographic) and numeric-promotion/enum/optional cases are unchanged.

## Success Criteria

- **SC-001**: `string == i32` and `bool < bool` report their tailored
  messages.
- **SC-002**: `string < string` and numeric comparisons still check.
- **SC-003**: `zig build` and `zig build test` stay green.

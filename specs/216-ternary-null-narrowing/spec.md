# Spec 216: null-narrowing in a ternary condition

## Goal

Narrow an optional binding to non-null in the guarded branch of a ternary, the
same way an `if` condition does:

```ts
const a: i32 | null = 5;
const b = a !== null ? a : 0;   // `a` is i32 in the then-branch -> 5

function f(a: i32 | null): i32 {
  return a !== null ? a * 2 : 0;
}
```

Previously `a !== null ? a : 0` reported `E_TYPE_MISMATCH` — the ternary did not
narrow `a`, so the then-branch still saw `i32 | null` and clashed with the
`i32` else-branch.

## Why additive, not breaking

Only makes previously-rejected programs compile. Ternaries with a non-narrowing
condition are unchanged, and if-statement narrowing already worked.

## Semantics

When a ternary condition is `x !== null` (or `x === null`), the guarded branch
narrows `x` to its non-optional inner type — the then-branch for `!== null`, the
else-branch for `=== null` — reusing the exact narrowing the if-statement uses
(the narrowed binding reads and emits as the unwrapped value).

## Requirements

- **FR-001**: `x !== null ? A : B` narrows `x` to non-null while checking `A`.
- **FR-002**: `x === null ? A : B` narrows `x` to non-null while checking `B`.
- **FR-003**: Ternaries without a null-check condition are unchanged.

## Success Criteria

- **SC-001**: `const b = a !== null ? a : 0` for `a: i32 | null = 5` yields `5`;
  `null` yields the fallback.
- **SC-002**: `a === null ? 0 : a` narrows in the else-branch.
- **SC-003**: `a !== null ? a * 2 : 0` inside a function works for a value and
  null.
- **SC-004**: `x > 3 ? "big" : "small"` (non-narrowing) is unchanged.
- **SC-005**: `zig build` and `zig build test` stay green.

# Spec 261: field-path narrowing and &&/|| short-circuit narrowing

## Goal

The remaining everyday narrowing idioms type-check:

```ts
if (u.email != null) {
  console.log(u.email.length)          // field path narrows
  console.log(u.email.toUpperCase())   // method on narrowed field
}
return s != null && s.length > 2       // && right side narrows
const ok: bool = s == null || s.length < 3   // || right side narrows
```

All previously "may be null" errors.

## Semantics

- Narrowing keys are paths: a plain variable or a single-level field read
  (`u.email`). A narrowed optional field types as its inner type and emits
  a runtime unwrap; deeper paths (`a.b.c`) remain future work.
- In `a && b`, when `a` is a positive null-check (`x != null`), `x` is
  narrowed while checking `b`; in `a || b`, a negative check (`x == null`)
  narrows `x` in `b`. One level (the left operand itself), matching the
  guard idioms.
- Existing if/ternary/guard-clause narrowing picks up field paths through
  the same `narrowTarget` upgrade.

## Success Criteria

- **SC-001**: The four probes compile and run with correct values on both
  null and non-null inputs.
- **SC-002**: Unnarrowed optional field reads still error with the
  may-be-null guidance.
- **SC-003**: `zig build` and `zig build test` stay green.

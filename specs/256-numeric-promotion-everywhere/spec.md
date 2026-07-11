# Spec 256: numeric promotion in comparisons, assignments, compound assigns

## Goal

Completes spec 255 — every place an integer meets an `f64` behaves like
TypeScript's single `number` type:

```ts
if (n < 5.5) { ... }         // i32 vs f64 comparison
console.log(f == 3)          // f64 vs int value
const f: f64 = n             // assignment
let sum: f64 = 0.0
sum += x                     // compound assignment, x: i32
return sum / xs.length       // int/float arithmetic (spec 255)
```

All previously "type mismatch".

## Semantics

- Comparisons (`< > <= >= == !=`) between an integer value and an `f64`
  promote the integer side to f64 (bare-literal special cases unchanged).
- `ensureAssignable` into an `f64` slot accepts any integer-typed value by
  wrapping it in the runtime `Number()` conversion — covering declarations,
  arguments, returns, array elements, and record fields.
- Compound arithmetic assignment onto an `f64` binding accepts an integer
  RHS the same way.
- Integer-only contexts (bitwise, shifts, i32/i64 slots) are unchanged —
  floats never silently narrow to integers.

## Success Criteria

- **SC-001**: The probes above compile and print correct float results
  (`avg([1,2,3,4])` → 2.5).
- **SC-002**: Assigning f64 to an i32 slot still errors.
- **SC-003**: `zig build` and `zig build test` stay green.

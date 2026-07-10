# Spec 113: for-of unused loop variable

## Goal

A `for (const x of ...)` loop whose body never uses `x` failed the native build
with a Zig "unused local constant" error, even though the program type-checks
and JavaScript allows an unused loop variable. This makes such loops compile —
common when iterating purely for a count or side effect.

## Why this is a codegen fix, not an API change

The loop lowers the element to a `const` binding each iteration. Zig requires
every local to be used, so codegen now emits `_ = &<binding>;` right after the
binding (unless the binding is the discard name `_`). This marks the variable
used without affecting behavior; a body that does use the element is unchanged.

## Scope

- Applies to `for-of` over strings and arrays.
- Array *literals* used directly as the iterable
  (`for (const x of [1, 2, 3])`) remain a separate, pre-existing limitation
  (the literal lowers to a tuple); iterate a typed array binding instead.

## Requirements

- **FR-001**: A `for-of` loop whose body ignores the loop variable compiles and
  runs, iterating the expected number of times.
- **FR-002**: A `for-of` loop that uses the loop variable is unchanged.

## Success Criteria

- **SC-001**: `for (const c of "abcde") { n = n + 1; }` leaves `n == 5`;
  `for (const x of arr) { sum = sum + 1; }` counts the elements; and a body
  that uses the element still sums correctly.
- **SC-002**: `zig build` and `zig build test` stay green.

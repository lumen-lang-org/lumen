# Spec 115: for-in unused loop variable

## Goal

Like `for-of` (spec 113), a `for (const k in ...)` loop whose body never uses
the key/index failed the native build with Zig's "unused local" error, though
JavaScript allows it. This makes such loops compile.

## Why this is a codegen fix, not an API change

Both `for-in` forms (record field names, and array indices formatted as
strings) bind the key to a `const` each iteration. Codegen now emits
`_ = &<binding>;` after that binding (unless it is the discard name `_`),
marking it used. Bodies that use the key are unchanged.

## Scope

- Applies to `for-in` over records (field-name keys) and arrays (index keys).
- Mirrors spec 113's fix for `for-of`.

## Requirements

- **FR-001**: A `for-in` loop whose body ignores the key compiles and runs,
  iterating the expected number of times.
- **FR-002**: A `for-in` loop that uses the key is unchanged.

## Success Criteria

- **SC-001**: For `arr = [10,20,30]`: `for (const i in arr) { n += 1; }` leaves
  `n == 3`, and `for (const i in arr) { keys += i; }` yields `"012"`.
- **SC-002**: `zig build` and `zig build test` stay green.

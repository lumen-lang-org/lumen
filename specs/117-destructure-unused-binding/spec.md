# Spec 117: unused destructured binding

## Goal

Destructuring where one of the names is not used later — e.g.
`const [a, b] = xs;` using only `b`, or object destructuring ignoring a field —
failed the native build with Zig's "unused local" error, though JavaScript
allows it. This makes such declarations compile.

## Why this is a codegen fix, not an API change

A destructuring declaration lowers to one `const` per element/field. Codegen
now emits `_ = &<binding>;` after each (unless it is the discard name `_`),
marking it used. Bindings that are used are unaffected.

## Scope

- Applies to array and object destructuring declarations.
- Completes the unused-binding fixes alongside for-of (113), for-in (115), and
  arrow parameters (116).

## Requirements

- **FR-001**: A destructuring declaration with one or more unused names
  compiles and binds the used names correctly.
- **FR-002**: A destructuring declaration whose names are all used is
  unchanged.

## Success Criteria

- **SC-001**: For `xs = [1,2,3]`: `const [a, b] = xs; b` -> `2` (a unused);
  `const [c, d, e] = xs; c + e` -> `4` (d unused); `const [p, q] = xs; p + q`
  -> `3`.
- **SC-002**: `zig build` and `zig build test` stay green.

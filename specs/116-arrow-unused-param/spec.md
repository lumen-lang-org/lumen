# Spec 116: unused arrow-function parameter

## Goal

An arrow function that ignores one of its parameters — very common with the
index-aware array callbacks, e.g. `xs.map((v, i) => i)` (ignores `v`) or
`xs.map((v, i) => v)` (ignores `i`) — failed the native build with Zig's
"unused function parameter" error, though JavaScript allows it. This makes such
callbacks compile.

## Why this is a codegen fix, not an API change

An arrow lowers to a Zig `fn __a(__ctx, p0, p1, ...) { ... }`. Zig requires
every parameter to be used. Codegen now emits `_ = &<param>;` for each
parameter (unless it is the discard name `_`) before the body, marking it used.
A body that does use the parameter is unaffected.

## Scope

- Applies to all arrow functions (capturing and non-capturing).
- Complements specs 113/115 (unused loop variables).

## Requirements

- **FR-001**: An arrow whose body ignores one or more parameters compiles and
  behaves as written.
- **FR-002**: An arrow that uses all its parameters is unchanged.

## Success Criteria

- **SC-001**: For `xs = [10,20,30]`: `xs.map((v, i) => i)` -> `[0,1,2]`,
  `xs.map((v, i) => v)` -> `[10,20,30]`, `xs.filter((v, i) => i > 0)` ->
  `[20,30]`.
- **SC-002**: `zig build` and `zig build test` stay green.

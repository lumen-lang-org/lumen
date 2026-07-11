# Spec 172: fix arrow closure fn name collision with slice locals

## Goal

Fix a codegen collision that made string-method chains inside an arrow callback
fail to build:

```ts
words.map(w => w[0].toUpperCase() + w.slice(1));  // title-case
words.filter(w => w.slice(0, 1) === "h");
```

Previously these produced a Zig `local constant shadows declaration of '__a'`
error.

## Root cause

Each arrow closure lowered to `struct { fn __a(...) { ... } }.__a`. The string
`slice`/`substring` codegen declares locals named `__a`/`__b` (the clamped
endpoints). When such a slice appeared inside an arrow body, its `const __a`
shadowed the enclosing `fn __a`, which Zig rejects.

## Fix

Rename the arrow closure's internal function from `__a` to `__afn` (a reserved
name), so it no longer collides with the generic `__a`/`__b` locals emitted by
slice and other inline blocks. The closure interface (`.call`) is unchanged.

## Requirements

- **FR-001**: A string `slice`/`substring` (or any block using `__a`/`__b`
  locals) inside an arrow body compiles.
- **FR-002**: Closure calls behave exactly as before.

## Success Criteria

- **SC-001**: `words.map(w => w[0].toUpperCase() + w.slice(1))` title-cases each
  word.
- **SC-002**: `words.filter(w => w.slice(0, 1) === "h")` and
  `words.map(w => w.length > 3 ? w.toUpperCase() : w)` compile and run.
- **SC-003**: `zig build` and `zig build test` stay green.

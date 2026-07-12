# Spec 335 — Diagnostic for extending a generic class

## Goal

Give a clear message when a class extends a generic base, instead of the
misleading "not a known class".

## Motivation

`class IntBox extends Container<i32>` (where `Container<T>` is generic) reported
`Container is not a known class`, because a generic class lives in the generic
registry rather than the concrete-class table. Extending a generic base is not
yet supported, but the message should say so and point at a workaround.

## Behavior

Extending a name that is a known generic class reports:

> extending a generic class (`Container<...>`) is not supported yet — extend a
> concrete (non-generic) base class, or compose it as a field instead of
> subclassing

Extending a genuinely unknown name, or `Error`, keeps its existing message.

## Implementation

- `src/lumen_check_stmt.zig`: `checkClass` checks the generic-class registry for
  the parent name before the generic unknown-base diagnostic.

## Verification

- `zig build` and `zig build test` green.
- Extending a generic class produces the guidance; extending an unknown class is
  unchanged.

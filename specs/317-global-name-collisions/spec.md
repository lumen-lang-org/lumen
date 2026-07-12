# Spec 317 — Reserved and colliding global function names

## Goal

Let a top-level function be named after a Zig keyword or a generated runtime
helper's parameter without producing invalid generated code:

```ts
function error(m: string) { return m; }   // `error` is a Zig keyword
function name(x: i32) { return x; }        // collides with a helper's `name` param
```

## Motivation

User global function names were emitted verbatim. A name that is a Zig keyword
(`error`, `type`, …) produced invalid Zig, and a name matching a generated
runtime helper's parameter (`name`, `value`, `data`, …) was rejected with
`function parameter shadows declaration of '…'`. Both surfaced as an opaque
"native backend rejected this statement" error.

## Behavior

Such names are renamed to a reserved `__lumen_user_<name>` form in the generated
code. The declaration, every call site, and function-reference wrappers all
route through the same `safeGlobalName`, so the rename is consistent (including
recursive calls). User-visible names and behavior are unchanged.

## Implementation

- `src/lumen_emit.zig`: `safeGlobalName` now also renames any name that is a Zig
  reserved word (via the existing `isZigReservedField` list) or matches a known
  generated-helper parameter identifier, in addition to the previous
  `main`/`std`/`xev`/`builtin` set.

## Verification

- `zig build` and `zig build test` green.
- Functions named `error`, `name`, `value`, `data`, etc. compile and run,
  including a recursive `name`, and an enum-dispatch function named `name`.

# Spec 337 — Diagnostic for `{ ... } as const`

## Goal

Give an actionable message when an object literal uses `as const`, instead of the
generic "cannot infer variable type":

```ts
const config = { port: 8080, host: "local" } as const;
```

## Motivation

`as const` is an identity assertion in Lumen (spec 307), and an object literal
cannot be typed on its own — it needs a named record type. Combining the two
(`{ ... } as const`) produced only "cannot infer variable type", with no hint
about the fix.

## Behavior

`{ ... } as const` reports:

> `as const` cannot type an object literal on its own — declare a named record
> type (`type T = { ... }`) and annotate `const x: T = { ... }`

Scalar and string `as const` (`5 as const`, `"hi" as const`) are unchanged.

## Implementation

- `src/lumen_check_expr.zig`: in the `as const` path, when the operand is an
  object literal that cannot self-type, emit the guidance message.

## Verification

- `zig build` and `zig build test` green.
- `{ ... } as const` produces the guidance; `5 as const` and `"hi" as const` still
  work.

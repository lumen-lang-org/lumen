# Spec 307 — `as const` assertion

## Goal

Accept `expr as const` as an identity assertion rather than rejecting it with a
bare `type mismatch`.

## Motivation

`const x = 5 as const;` previously failed because `const` was resolved as an
ordinary (nonexistent) type, producing `type mismatch [E_TYPE_MISMATCH]`. The
`as const` const-assertion is common idiomatic TypeScript.

## Behavior

Lumen has no value-level literal types, so a const assertion cannot narrow a
value to a literal type. It is therefore treated as an identity assertion: the
operand keeps its own type and the assertion is erased at emit.

```ts
const x = 5 as const;       // x: i32
const s = "hi" as const;    // s: string
const y: i32 = x + 1;       // ok
```

Regular `as T` casts are unchanged, including the rejection of disallowed casts
(`"x" as i32` still errors).

## Implementation

- `src/lumen_check_expr.zig`: in the `.cast` handler, when the annotation text
  is `const`, return the operand's own type (recorded as `checked_type`)
  instead of resolving `const` as a type.
- Emit already erases casts, so `as const` needs no codegen change.

## Verification

- `zig build` and `zig build test` green.
- `5 as const`, `"hi" as const` check; the results are usable at their operand
  type. `"x" as i32` still errors.

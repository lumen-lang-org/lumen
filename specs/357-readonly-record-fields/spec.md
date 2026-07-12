# 357 — `readonly` modifier on record and interface fields

## Problem

`readonly` was supported on class fields (parse + three-way enforcement) but a
hard parse error on record types and interfaces:

```ts
type P = { readonly x: i32 };      // error: expected ':', found 'x'
interface Q { readonly n: i32 }    // same
```

Very common TypeScript idiom; real-world type declarations failed at parse.

## Change

1. **Parser** (`lumen_parser_decl.zig`, type-body and interface-body loops):
   an identifier `readonly` followed by another identifier is the modifier and
   sets `TypeField.is_readonly`; `readonly: T` stays a field literally named
   `readonly`. Composes with optional members (`readonly x?: i32`).

2. **Checker enforcement** (`lumen_check_stmt.zig`): records are already
   immutable in V1 except through a `Ref<T>` parameter, so the one writable
   path now checks the modifier: writing a `readonly` field through `Ref<T>`
   fails with the existing `E_READONLY_ASSIGNMENT`. New helper
   `Checker.recordFieldReadonly`.

## Verified

`zig build` + `zig build test` green. Probes:

- `type P = { readonly x: i32, y: i32 }` — parses, reads work (prints 3).
- `interface Q { readonly n: i32 }` — parses, works through an alias.
- `type S = { readonly: bool }` — field named `readonly` still works.
- `readonly x?: i32` — composes with optional members.
- `Ref<Counter>` write to non-readonly field still allowed (`c.n = c.n + 1`);
  write to `readonly id` rejected: `cannot assign to a 'readonly' field
  [E_READONLY_ASSIGNMENT]`.

## Boundary

`readonly T[]` / `ReadonlyArray<T>` array-type annotations are a separate
type-syntax feature, not covered here (arrays are already immutable in V1
anyway). Class-field `readonly` behavior is unchanged.

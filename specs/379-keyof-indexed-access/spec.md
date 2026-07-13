# 379 — `keyof` and indexed-access types

Second step into type-level programming, composing with the spec 378 utility
types.

## Problem

`keyof P` and indexed-access `P["field"]` were parse/type errors:

```ts
type K = keyof P;    // error: expected end of statement, found 'P'
type X = P["x"];     // error: expected ']', found a string
```

## Change

1. **Parser** (`lumen_parser_expr.zig`):
   - `parseTypeMember` recognizes a `keyof <name>` prefix (handled here so it
     also works in a bare alias RHS `type K = keyof P`), producing the
     annotation `keyof P`.
   - the `[…]` suffix loop accepts a string literal — `P["x"]` becomes the
     annotation `P["x"]` instead of being read as an array suffix.
2. **Checker** (`lumen_check.zig`, `typeFromAnnotation`):
   - `keyof P` resolves the operand (so it works over a utility type too),
     collects the record's field names, and registers a synthetic
     string-literal union `__keyof_P` — a value of type `keyof P` is a string
     constrained to the field names. No struct emission (it erases to `string`).
   - `P["field"]` resolves the base (utility types included) and returns that
     field's declared type.
3. **Assignability** (`lumen_check_assign.zig`): a string-literal union (which
   now includes `keyof P`) widens to `string` on assignment/return — both erase
   to the same runtime value. Invalid-key diagnostics display `keyof P`, not the
   internal mangled name.

## Verified

`zig build` + `zig build test` green. Probes:

- `type K = keyof P; const k: K = "x"` — accepted; `"z"` rejected with
  *"z" is not a valid `keyof P` — expected "x" | "y"*.
- `keyof P` as a parameter type, returned as/concatenated with `string`.
- `type X = P["x"]` — `X` is the field's type (`i32`, `string`, …), usable in
  values and as a parameter type.
- Composition: `keyof Pick<P, "a" | "b">` and `Partial<P>["x"]`.

## Boundary

`keyof` yields a union of the record's own field names only; indexed access
takes a single string-literal key (not `P[keyof P]` or a key union). Mapped and
conditional types remain unsupported.

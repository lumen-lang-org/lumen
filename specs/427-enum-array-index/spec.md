# 427 — a numeric enum value is a valid array/string index

## Problem

Indexing with a numeric enum member failed:

```ts
enum Color { Red, Green, Blue }
const names = ["Red", "Green", "Blue"];
names[Color.Green]; // error: type mismatch [E_TYPE_MISMATCH]
```

The index check accepted `i32`/`i64` (and, since spec 426, `f64`), but not an
`enum_type` — even though a numeric enum backs as an integer at runtime.

## Approach

`lumen_check_expr.zig`, index-access check: treat a numeric (non-string) enum
index as a valid integer index; it already lowers to its `i32` backing value in
the generated code. String enums remain rejected.

## Verification

- `names[Color.Green]` → `Green`; `vals[E.C]` → `30`.
- A string-enum index still reports a type error.
- Integer, `i64`, and `number` (truncating) indices unchanged.
- Full `zig build` + test suite green.

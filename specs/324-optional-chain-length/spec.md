# Spec 324 — Optional chaining into `.length` / `.size`

## Goal

Allow optional chaining into the builtin `length`/`size` members:

```ts
const s: string | null = null;
console.log(s?.length ?? 0);          // 0

type P = { name?: string };
const p: P = {};
console.log(p.name?.length ?? -1);    // -1
```

## Motivation

Optional chaining (`?.`) only resolved a record field on the unwrapped value, so
`s?.length` on a nullable string (or array/map/set) reported a bare
`type mismatch`. Guarding a possibly-null string/array before reading its length
is a very common null-safety pattern.

## Behavior

When the receiver of `?.` is an optional `string`/array (`?.length`), an optional
`Map`/`Set` (`?.size`), or an optional `Buffer` (`?.length`), the chain yields
`i32 | null` — the length/size when present, `null` when the receiver is null.
Record-field chaining is unchanged.

## Implementation

- `src/lumen_check_expr.zig`: the optional-chain field handler recognizes the
  `length`/`size` builtins on the unwrapped inner type (in addition to record
  fields) and types the result as `i32 | null`.
- `src/lumen_emit.zig`: the optional-chain lowering emits the builtin's Zig form
  on the unwrapped value (`__oc.len` / `__oc.size()`), not a literal `.length`
  member access.

## Verification

- `zig build` and `zig build test` green.
- `s?.length`, `xs?.length`, an optional record field `p.name?.length`, and a
  nullable array all evaluate correctly for both the present and null cases;
  record-field optional chaining is unchanged.

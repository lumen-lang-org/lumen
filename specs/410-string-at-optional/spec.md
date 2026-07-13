# 410 — `String.prototype.at` returns `string | null`

## Problem

`str.at(i)` was typed as a plain non-optional `string` and returned `""` for an
out-of-range index. That contradicts JS/TS, where `String.prototype.at` is
`string | undefined`, and it broke the natural fallback pattern:

```ts
"ab".at(5) ?? "none"; // error: left side of `??` is `string`, which can never be null
```

Array `.at` already correctly returned `T | null`; string `.at` was the
inconsistent one — and its non-optional type was a soundness hole (it claimed
non-null while an out-of-range access is semantically absent).

## Approach

- **Check** (`lumen_check_methods.zig`): after the string-method spec dispatch,
  special-case `at` to return `string | null` (optional). `charAt` keeps
  returning a plain `string` (JS `charAt` yields `""` for out-of-range, not
  `undefined`).
- **Emit** (`lumen_emit_array_string.zig`): `str.at(i)` now yields
  `@as(?[]const u8, … else null)` — the character slice in range, `null` out of
  range.

## Verification

- `"ab".at(5) ?? "none"` → `none`; `"abc".at(1) ?? "?"` → `b`;
  `"abc".at(-1) ?? "?"` → `c`.
- Null-narrowing (`if (c != null)`) works on the result.
- `charAt` unchanged: `"abc".charAt(1)` → `b`, out-of-range → `""`.
- Reverse-iteration and template/concat usages work with `?? ""`.
- Full `zig build` + test suite green.

## Notes

Breaking for code that used `str.at(i)` directly as a `string`; such code now
needs `?? ""` or a null check — the type-safe, TS-correct requirement.

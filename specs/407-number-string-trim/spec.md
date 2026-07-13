# 407 — `Number(string)` trims whitespace and maps empty to 0

## Problem

`Number(s)` on a string didn't match JavaScript for padded or empty input:

```ts
Number("  42  "); // NaN   (JS: 42)
Number("");        // NaN   (JS: 0)
Number("   ");     // NaN   (JS: 0)
```

The conversion called `std.fmt.parseFloat` on the raw string, which rejects
surrounding whitespace and an empty string. This also reached the `+x` unary
operator, which now lowers to `Number(x)` (spec 406).

## Approach

`lumen_emit.zig`, the `Number(x)` global-conversion emit: for the string case,
trim ASCII whitespace (`" \t\n\r"`) first; an empty/whitespace-only result is
`0`, otherwise `parseFloat` the trimmed slice (still NaN on a genuine
non-number). Numeric and boolean operands are unchanged.

## Verification

- `Number("  42  ")` → `42`; `Number("  3.14 ")` → `3.14`.
- `Number("")` and `Number("   ")` → `0`.
- `Number("42")` → `42`; `Number("abc")` → `NaN`; `Number(5)` → `5`.
- `+"  10  " + 1` → `11`.
- Full `zig build` + test suite green.

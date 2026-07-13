# Spec 433 — `number.toLocaleString()`

## Problem

The number instance methods (`toFixed`, `toString`, `toPrecision`,
`toExponential`) were implemented, but `toLocaleString()` — commonly used to
render a count with thousands separators — was rejected:

```
error: `i32` has no method 'toLocaleString'
```

## Change

`toLocaleString()` (no arguments) is accepted on any numeric receiver and
returns `string`. It emits a call to a new prelude helper `__numLocaleString`,
gated behind `program.needs_to_locale`, that formats using the ECMAScript en-US
default:

- the integer part is grouped into comma-separated thousands,
- up to 3 fraction digits are kept, trailing zeros trimmed,
- a leading `-` is preserved for negatives.

An integer receiver is widened to `f64` before formatting, mirroring the other
number methods.

## Verification

- `zig build` and `zig build test` clean.
- Matches JavaScript:
  - `(1000000).toLocaleString()` → `1,000,000`
  - `(1234).toLocaleString()` → `1,234`
  - `(999).toLocaleString()` → `999`
  - `(-1234567).toLocaleString()` → `-1,234,567`
  - `(1234.5678).toLocaleString()` → `1,234.568`
  - `(1234.5).toLocaleString()` → `1,234.5`
  - `(0).toLocaleString()` → `0`

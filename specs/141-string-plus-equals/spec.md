# Spec 141: string concatenation with +=

## Goal

Allow `+=` on a string variable to concatenate, matching `s = s + x`:

```ts
let s = "x";
s += "y";       // "xy"  (was E_TYPE_MISMATCH)
let out = "";
for (let i = 0; i < 3; i++) out += "ab";   // "ababab"
```

Previously `+=` required a numeric left-hand side, so string accumulation — one
of the most common uses of `+=` — was rejected even though `s + x` and
`s = s + x` already worked.

## Why additive, not breaking

Only makes previously-rejected programs compile. Numeric `+=` is unchanged. A
string `+=` with a non-string right-hand side still reports `E_TYPE_MISMATCH`
(consistent with Lumen's strict `+`, which does not auto-coerce).

## Semantics

`s += x`, where `s` is a string, folds to `s = s + x`: the two strings are
concatenated into a new string. It mirrors the existing binary `+`
string-concatenation lowering (`std.mem.concat`).

## Requirements

- **FR-001**: `+=` on a string target with a string right-hand side
  concatenates.
- **FR-002**: `+=` on a string target with a non-string right-hand side reports
  `E_TYPE_MISMATCH`.
- **FR-003**: Numeric `+=` is unchanged.

## Success Criteria

- **SC-001**: `let s = "x"; s += "y"; s += "z";` gives `s == "xyz"`.
- **SC-002**: Accumulating `out += "ab"` three times gives `"ababab"`.
- **SC-003**: `let n = 5; n += 3;` gives `n == 8`.
- **SC-004**: `zig build` and `zig build test` stay green.

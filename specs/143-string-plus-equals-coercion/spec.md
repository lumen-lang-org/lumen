# Spec 143: += coerces a number/bool onto a string

## Goal

Complete the string-concatenation story (specs 141, 142): `+=` onto a string now
coerces a number or boolean right-hand side to string, mirroring `s = s + x`:

```ts
let s = "n=";
s += 5;        // "n=5"    (was E_TYPE_MISMATCH)
s += true;     // "n=5true"
let out = "";
for (let i = 0; i < 3; i++) out += i;   // "012"
```

The `out += i` loop pattern — building a string from numbers — is extremely
common and previously failed to compile.

## Why additive, not breaking

Only makes previously-rejected programs compile. String `+=` with a string
right-hand side (spec 141) and numeric `+=` are unchanged; a non-coercible
right-hand side (array, object) still reports `E_TYPE_MISMATCH`.

## Semantics

`s += x`, where `s` is a string: if `x` is a number or boolean it is wrapped in
the runtime `String(...)` conversion (spec 142's mechanism) and concatenated,
exactly as `s = s + x` would.

## Requirements

- **FR-001**: `+=` on a string coerces a number/boolean right-hand side to
  string and concatenates.
- **FR-002**: A non-string, non-numeric, non-boolean right-hand side still
  reports `E_TYPE_MISMATCH`.
- **FR-003**: Numeric `+=` and string-RHS `+=` are unchanged.

## Success Criteria

- **SC-001**: `let s = "n="; s += 5; s += true; s += "!";` gives `n=5true!`.
- **SC-002**: `let out = ""; for (let i = 0; i < 3; i++) out += i;` gives `012`.
- **SC-003**: `zig build` and `zig build test` stay green.

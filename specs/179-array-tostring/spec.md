# Spec 179: `array.toString()`

## Goal

Support `Array.prototype.toString()`, the comma-joined string form:

```ts
[1, 2, 3].toString();      // "1,2,3"
["x", "y"].toString();     // "x,y"
[true, false].toString();  // "true,false"
```

Previously an array `.toString()` reported `E_TYPE_MISMATCH` — only `.join(sep)`
was available, and `.join()` with no argument already produced the comma form.

## Why additive, not breaking

Only makes previously-rejected programs compile. `a.join(sep)` and a number's
`.toString(radix)` are unchanged.

## Semantics

`a.toString()` is identical to `a.join(",")`: each element is formatted (numbers
as decimals, booleans as `true`/`false`, strings verbatim) and concatenated with
a comma separator.

## Requirements

- **FR-001**: `a.toString()` returns the comma-joined elements as a string.
- **FR-002**: Works for number, string, and bool element arrays.
- **FR-003**: `a.join(sep)` and a number receiver's `.toString(radix)` are
  unchanged.

## Success Criteria

- **SC-001**: `[1,2,3].toString()` -> `1,2,3`; `["x","y"].toString()` -> `x,y`.
- **SC-002**: `[true,false].toString()` -> `true,false`.
- **SC-003**: `(255).toString(16)` -> `ff`; `[1,2,3].join("-")` -> `1-2-3`.
- **SC-004**: `zig build` and `zig build test` stay green.

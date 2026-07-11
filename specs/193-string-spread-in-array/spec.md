# Spec 193: spreading a string into an array literal

## Goal

Support `[...str]`, spreading a string into an array of its single-character
strings:

```ts
[..."abc"];                    // ["a", "b", "c"]
[..."hello"].reverse().join(""); // "olleh"
["x", ..."ab", "y"];            // ["x", "a", "b", "y"]
```

Previously a string spread in an array literal reported `E_TYPE_MISMATCH`.
Companion to spec 192 (Set spread).

## Why additive, not breaking

Only makes previously-rejected programs compile. Array and Set spreads are
unchanged.

## Semantics

`[...str]` contributes each character of `str` (as a one-character string, the
same element form as `Array.from(str)` and string iteration) to the array. It
composes with other entries and spreads. Implemented by rewriting the string
spread source to `Array.from(str)` during checking, so it flows through the
existing array-spread path.

## Requirements

- **FR-001**: `[...str]` yields the string's characters as `string[]`.
- **FR-002**: Composes with plain entries and other spreads.
- **FR-003**: Array and Set spreads are unchanged.

## Success Criteria

- **SC-001**: `[..."abc"].join("-")` -> `a-b-c`.
- **SC-002**: `[..."hello"].reverse().join("")` -> `olleh`.
- **SC-003**: `["x", ..."ab", "y"]` -> `["x","a","b","y"]`.
- **SC-004**: `zig build` and `zig build test` stay green.

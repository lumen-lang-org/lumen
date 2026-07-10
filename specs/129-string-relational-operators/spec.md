# Spec 129: String relational operators

## Goal

Allow the relational operators `<`, `>`, `<=`, `>=` between two strings, with
JavaScript's lexicographic (byte-order) semantics: `"a" < "b"` is `true`,
`"abc" < "abd"` is `true`, `"ab" < "abc"` is `true`.

## Why additive, not breaking

Before this slice string operands were accepted only for `==` / `!=`; the
relational operators reported `E_TYPE_MISMATCH`. Nothing that compiled before
changes — this only makes previously-rejected programs compile.

## API

Not a library API. The four relational operators gain a string overload:

- `a < b`, `a > b`, `a <= b`, `a >= b` where both operands are strings — each
  yields `boolean` from a lexicographic comparison of the UTF-8 bytes.

## Requirements

- **FR-001**: Both operands must be strings. A string compared against a
  non-string with a relational operator still reports `E_TYPE_MISMATCH`.
- **FR-002**: The comparison is byte lexicographic — the same order
  `std.mem.order(u8, ...)` produces, matching JS for ASCII text.
- **FR-003**: `==` / `!=` string semantics are unchanged (content equality).

### Diagnostics
Reuses `E_TYPE_MISMATCH`.

## Success Criteria

- **SC-001**: `"a" < "b"` -> `true`; `"b" < "a"` -> `false`;
  `"a" <= "a"` -> `true`; `"b" > "a"` -> `true`; `"a" >= "b"` -> `false`;
  `"abc" < "abd"` -> `true`; `"ab" < "abc"` -> `true`.
- **SC-002**: `"a" < 3` reports `E_TYPE_MISMATCH`.
- **SC-003**: `zig build` and `zig build test` stay green.

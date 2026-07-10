# Spec 144: string index access s[i]

## Goal

Let `s[i]` on a string return the single-character substring at index `i`, as in
JavaScript/TypeScript:

```ts
const s = "Hello";
s[0]            // "H"   (was E_TYPE_MISMATCH)
s[1] + s[2]     // "el"
for (let i = 0; i < s.length; i++) console.log(s[i]);
```

Previously bracket indexing was only defined for arrays; a string index reported
`E_TYPE_MISMATCH`, forcing `s.charAt(i)`.

## Why additive, not breaking

Only makes previously-rejected programs compile. Array indexing is unchanged.

## Semantics

`s[i]` where `s` is a string evaluates to the one-byte substring `s[i..i+1]`,
typed as `string` (TS types `s[i]` as `string`, not a distinct char type). The
index is an integer. As with the existing array indexing, an out-of-range index
is a runtime bounds check, not a compile error.

## Requirements

- **FR-001**: `s[i]` on a string yields a length-1 string.
- **FR-002**: The result composes with string operations (`+`, `===`, method
  calls).
- **FR-003**: Array index access is unchanged.

## Success Criteria

- **SC-001**: `"Hello"[0]` -> `H`; `"Hello"[4]` -> `o`;
  `"Hello"[1] + "Hello"[2]` -> `el`.
- **SC-002**: `"abc"[0] === "a"` -> `true`.
- **SC-003**: Iterating `s[i]` for `i` in `0..s.length` prints each character.
- **SC-004**: `zig build` and `zig build test` stay green.

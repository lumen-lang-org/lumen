# Spec 142: string + number concatenation

## Goal

Match TypeScript's `+` operator: when either operand is a string, the result is
a string and the other operand (a number or boolean) is coerced to its string
form:

```ts
"a" + 1        // "a1"    (was E_TYPE_MISMATCH)
1 + "a"        // "1a"
"n=" + 42 + "!"  // "n=42!"
"v=" + true    // "v=true"
```

Previously `+` required both operands to be strings (or both numeric), so mixing
a string and a number — one of the most common expressions in real code — failed
to compile.

## Why additive, not breaking

Only makes previously-rejected programs compile. Pure numeric `+` is unchanged,
and non-coercible operands (arrays, objects) with `+` still report
`E_TYPE_MISMATCH`.

## Semantics

For `a + b` where at least one side is a string:

- The other side must be a string, number, or boolean; anything else is a type
  error.
- The non-string side is wrapped in the runtime `String(...)` conversion (a
  number formats as its decimal text, a boolean as `true`/`false`), and the two
  strings are concatenated.
- Operator associativity is unchanged: `1 + 2 + "=three"` evaluates `1 + 2`
  numerically first, then concatenates, giving `"3=three"`.

## Requirements

- **FR-001**: `string + number`, `number + string`, `string + boolean`, and
  `boolean + string` all produce the concatenated string.
- **FR-002**: `string + array` / `string + object` still report
  `E_TYPE_MISMATCH`.
- **FR-003**: Pure numeric `+` is unchanged.

## Success Criteria

- **SC-001**: `"a" + 1` -> `a1`; `1 + "a"` -> `1a`; `"n=" + 42 + "!"` ->
  `n=42!`; `"v=" + true` -> `v=true`; `"x" + 1.5` -> `x1.5`.
- **SC-002**: `1 + 2 + "=three"` -> `3=three`; `2 + 3` -> `5`.
- **SC-003**: `[1,2] + "x"` reports `E_TYPE_MISMATCH`.
- **SC-004**: `zig build` and `zig build test` stay green.

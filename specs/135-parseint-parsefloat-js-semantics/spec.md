# Spec 135: JS semantics for parseInt / parseFloat

## Goal

Make `parseInt` and `parseFloat` (both the global forms and the `Number.*`
forms) parse a leading numeric prefix and ignore trailing garbage, as
JavaScript does:

```ts
parseInt("  42px")       // 42   (was null)
parseInt("0xff")         // 255  (was null)
parseFloat("3.14abc")    // 3.14 (was null)
parseFloat("  -2.5e3xy") // -2500
```

Previously these lowered to `std.fmt.parseInt` / `std.fmt.parseFloat`, which
require the *entire* string to be a valid number, so any surrounding whitespace
or trailing text produced `null`.

## Why a fix, not a feature

The functions already existed but diverged from JS whenever the input was not a
clean, whole numeric string. This aligns them with the documented behavior.

## Semantics

Both skip leading ASCII whitespace and read an optional `+`/`-` sign.

`parseInt(s, radix?)`:
- With no radix (or radix `0`), a `0x`/`0X` prefix selects base 16; otherwise
  base 10. An explicit radix of 16 also accepts the `0x` prefix.
- Consumes digits valid for the radix (`0-9`, `a-z`/`A-Z` for higher bases) and
  stops at the first invalid character.
- No valid digit -> `null`. A result outside the 32-bit signed range -> `null`.

`parseFloat(s)`:
- Consumes the longest prefix that parses as a float (digits, one `.`, an
  exponent). No valid number -> `null`.

## Requirements

- **FR-001**: Leading whitespace and a trailing non-numeric suffix are ignored.
- **FR-002**: `parseInt` honors a `0x` prefix when the radix is unspecified or
  16, and honors an explicit radix otherwise.
- **FR-003**: `Number.parseInt` / `Number.parseFloat` behave identically to the
  global forms.
- **FR-004**: No parseable number yields `null`.

## Success Criteria

- **SC-001**: `parseInt("  42px")` -> `42`; `parseInt("0xff")` -> `255`;
  `parseInt("0xff", 10)` -> `0`; `parseInt("ff", 16)` -> `255`;
  `parseInt("101", 2)` -> `5`; `parseInt("-17")` -> `-17`;
  `parseInt("abc")` -> `null`; `parseInt("z", 36)` -> `35`.
- **SC-002**: `parseFloat("3.14abc")` -> `3.14`;
  `parseFloat("  -2.5e3xyz")` -> `-2500`; `parseFloat(".5")` -> `0.5`;
  `parseFloat("abc")` -> `null`.
- **SC-003**: `Number.parseInt("0x10")` -> `16`;
  `Number.parseFloat("1.5rem")` -> `1.5`.
- **SC-004**: `zig build` and `zig build test` stay green.

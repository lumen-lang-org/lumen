# Spec 123: global String(x) conversion

## Goal

`String(x)` is JavaScript's global value-to-string conversion. Adding it gives a
uniform way to stringify a number, boolean, or string without reaching for
`.toString()` per type.

## Why additive, not breaking

`String(x)` is recognized as a conversion call (when no user function shadows
`String`), separate from the `String.*` static namespace, which is unchanged.
Codegen selects the formatting with a `@typeInfo` comptime branch: booleans and
numbers are formatted, a string passes through.

## API

- `String(x: number | bool | string): string` — the value's string form:
  decimal for numbers, `true`/`false` for booleans, and the string itself for
  strings.

## Requirements

- **FR-001**: Takes exactly one argument of numeric, boolean, or string type; an
  unsupported type reports `E_TYPE_MISMATCH`, a wrong count reports
  `E_ARG_COUNT`.
- **FR-002**: `String.*` static methods (`fromCharCode`, `compare`, …) are
  unaffected.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `String(42)` -> `"42"`, `String(3.14)` -> `"3.14"`,
  `String(true)` -> `"true"`, `String("hi")` -> `"hi"`.
- **SC-002**: `zig build` and `zig build test` stay green.

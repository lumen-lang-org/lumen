# Spec 124: global Boolean(x) conversion

## Goal

`Boolean(x)` is JavaScript's global truthiness conversion. Adding it gives an
explicit way to reduce a number, string, or boolean to `true`/`false`.

## Why additive, not breaking

`Boolean(x)` is recognized as a conversion call (when no user function shadows
`Boolean`) returning `bool`. Codegen selects the test with a `@typeInfo`
comptime branch. Nothing existing changes.

## API

- `Boolean(x: number | bool | string): bool` — truthiness: a nonzero number, a
  nonempty string, or the boolean itself.

## Requirements

- **FR-001**: Takes exactly one argument of numeric, boolean, or string type; an
  unsupported type reports `E_TYPE_MISMATCH`, a wrong count reports
  `E_ARG_COUNT`.
- **FR-002**: `0` / `0.0` / `""` / `false` are falsy; every other value is
  truthy.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Boolean(1)` -> `true`, `Boolean(0)` -> `false`, `Boolean("hi")`
  -> `true`, `Boolean("")` -> `false`, `Boolean(false)` -> `false`.
- **SC-002**: `zig build` and `zig build test` stay green.

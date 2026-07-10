# Spec 102: string concat

## Goal

String concatenation was only available via the `+` operator. `concat` is the
method form and, unlike `+`, is variadic — joining a receiver with any number of
string arguments in one call.

## Why additive, not breaking

Pure addition to `stringMethod`, validated directly (it is variadic, so it
doesn't fit the fixed-arity spec table). Nothing existing changes.

## API

Instance method on a `string` value:

- `concat(...strings: string): string` — the receiver followed by every
  argument, concatenated. At least one argument is required.

## Requirements

- **FR-001**: Requires one or more `string` arguments; a non-string argument
  reports `E_TYPE_MISMATCH`, zero arguments reports `E_ARG_COUNT`.
- **FR-002**: The result is the receiver followed by the arguments in order;
  empty-string arguments contribute nothing.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `"foo".concat("bar")` -> `"foobar"`,
  `"a".concat("b", "c", "d")` -> `"abcd"`,
  `"Hello, ".concat("World", "!")` -> `"Hello, World!"`.
- **SC-002**: `zig build` and `zig build test` stay green.

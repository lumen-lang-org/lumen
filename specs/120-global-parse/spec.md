# Spec 120: global parseInt / parseFloat

## Goal

`parseInt(...)` and `parseFloat(...)` are global functions in JavaScript, not
only `Number.parseInt` / `Number.parseFloat`. Supporting the bare global names
lets common code compile without the `Number.` prefix.

## Why additive, not breaking

The bare names are recognized as builtins only when no user function of that
name shadows them (a user `function parseInt(...)` takes precedence). They
produce the same optional result as the `Number.*` forms and lower to the same
`std.fmt.parse*` caught to null. A `is_global_parse` flag on the call node marks
the builtin so a user-shadowed call is emitted normally.

## API

- `parseInt(s: string, radix?: int): int | null` — as `Number.parseInt`.
- `parseFloat(s: string): f64 | null` — as `Number.parseFloat`.

## Requirements

- **FR-001**: `parseInt` takes a string and optional integer radix; `parseFloat`
  a single string. Non-string input or non-integer radix reports
  `E_TYPE_MISMATCH`; wrong argument count reports `E_ARG_COUNT`.
- **FR-002**: A user-defined function named `parseInt`/`parseFloat` shadows the
  global and is called normally.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `parseInt("42") ?? -1` -> `42`, `parseInt("ff", 16) ?? -1` ->
  `255`, `parseInt("xyz") ?? -1` -> `-1`, `parseFloat("3.14") ?? -1.0` ->
  `3.14`; and a user `function parseInt(...)` overrides the global.
- **SC-002**: `zig build` and `zig build test` stay green.

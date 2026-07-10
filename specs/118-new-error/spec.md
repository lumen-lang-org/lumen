# Spec 118: new Error(message)

## Goal

`throw new Error("msg")` — the most common way to raise an error in JavaScript
and TypeScript — failed to type-check (`E_TYPE_MISMATCH`), even though the
call form `throw Error("msg")` already worked. This makes the `new` form
equivalent.

## Why additive, not breaking

`new Error("msg")` is now recognized (when no user class named `Error` shadows
it) as producing the same `error_obj` value as `Error("msg")`: a single string
message. The checker validates one string argument and returns `error_obj`;
codegen emits the message expression, identical to the call form. Nothing
existing changes.

## Scope

- Only the single-string-message `Error` is covered, matching the existing
  `Error(...)` call.
- Cross-function throw propagation (a `throw` inside a callee being caught by a
  caller's `try`) is a separate, pre-existing limitation and is unchanged —
  `new Error` behaves exactly as `Error(...)` does today.

## API

- `new Error(message: string)` — an error value whose `.message` is `message`,
  usable with `throw` and readable in a `catch` binding.

## Requirements

- **FR-001**: `new Error(msg)` requires exactly one `string` argument; a
  non-string argument reports `E_TYPE_MISMATCH`, a wrong count reports
  `E_ARG_COUNT`.
- **FR-002**: `new Error(msg)` produces the same value and `.message` behavior
  as `Error(msg)`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `try { throw new Error("boom"); } catch (e) { ... e.message }`
  compiles and yields `"boom"`.
- **SC-002**: `zig build` and `zig build test` stay green.

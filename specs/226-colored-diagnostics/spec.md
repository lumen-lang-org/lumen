# Spec 226: colored diagnostics

## Goal

Render diagnostics with ANSI color when stderr is a terminal:

- `file:line:col:` in cyan,
- `error:` in bold red,
- the message in bold,
- the source-excerpt gutter dimmed and the caret in green.

## Semantics

Color is decided once at startup: on when stderr is a TTY and the `NO_COLOR`
environment variable is unset; otherwise every diagnostic renders as plain
text, byte-identical to the previous output — piped/redirected output and CI
logs are unchanged.

## Success Criteria

- **SC-001**: Under a TTY the error header carries the ANSI sequences.
- **SC-002**: Piped output has no escape sequences; `NO_COLOR=1` disables
  color under a TTY.
- **SC-003**: `zig build` and `zig build test` stay green.

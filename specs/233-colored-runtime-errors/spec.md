# Spec 233: colored runtime errors

## Goal

Runtime error output matches compile-time diagnostics: cyan position, bold-red
`Uncaught Error:`/`runtime error:`, dim excerpt gutter, green caret — when
stderr is a terminal.

## Semantics

The generated program decides color once at startup (stderr is a TTY and
`NO_COLOR` unset) and the panic handler renders accordingly. Piped/redirected
output stays byte-identical plain text. Programs compiled without the I/O
runtime (no `console.log` etc.) have no `Init` main and always print plain.

## Success Criteria

- **SC-001**: Under a TTY the runtime error header/excerpt/caret carry ANSI
  sequences; piped output has none.
- **SC-002**: `zig build` and `zig build test` stay green.

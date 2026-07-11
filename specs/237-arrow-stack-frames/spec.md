# Spec 237: arrow functions appear in stack traces

## Goal

A throw inside an arrow function gets its own stack frame instead of being
attributed to the caller:

```text
main.ts:5:14: Uncaught Error: too big
  5 |   if (x > 2) throw new Error("too big")
    |              ^
    at g (main.ts:5:14)
    at apply (main.ts:2:3)
    at <main> (main.ts:8:1)
```

Previously only named function declarations and class methods pushed frames;
the innermost arrow frame was missing and the error line was attributed to the
enclosing function.

## Semantics

Every arrow function body pushes a stack frame on entry and pops on exit,
matching function declarations. The frame name is the variable the arrow was
bound to (`const g = (x) => ...` traces as `g`); an arrow passed inline traces
as `<anonymous>`. Applies to both expression-body and block-body arrows, only
when the program is compiled with runtime location tracking (the default).

## Success Criteria

- **SC-001**: A throw inside a named-binding arrow shows `at <name> (...)` as
  the innermost frame, with the caller's frame showing its own call site.
- **SC-002**: An inline arrow shows `at <anonymous> (...)`.
- **SC-003**: Arrows that don't throw behave identically (`map` callback
  probe); `zig build` and `zig build test` stay green.

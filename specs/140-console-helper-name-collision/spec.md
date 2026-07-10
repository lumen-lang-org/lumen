# Spec 140: console output helper no longer shadows user names

## Goal

Continue the fix from spec 139: a top-level function named `w`, `buf`, `fmt`, or
`args` must not break the build. These collided with locals inside the always-
emitted `__consoleOut` helper.

```ts
function w(n: i32): i32 { return n; }
function y(n: i32): i32 { return n; }
console.log(w(1) + y(2));   // 3  (previously: local variable shadows 'w')
```

## Root cause

`__consoleOut` — emitted for every program that uses `console.log` — declared
`var buf`, `var w`, and took `fmt`/`args` parameters. A user function named `w`
(etc.) was shadowed by these bare locals, a Zig compile error. Spec 139 fixed
the regex-runtime and parse-helper collisions; this covers the console path,
which is emitted far more often.

## Fix

Rename `__consoleOut`'s locals and parameters to the reserved `__` prefix
(`__buf`, `__w`, `__fmt`, `__args`), following the same principle: every
always-emitted prelude identifier must be `__`-prefixed so it cannot shadow a
user identifier.

## Requirements

- **FR-001**: A top-level function named `w`, `buf`, `fmt`, or `args` compiles
  and runs when the program uses `console.log`.
- **FR-002**: `console.log` output is unchanged.

### Out of scope
Feature-gated helpers (fs/readLink, inotify watch, child_process, ...) still use
some bare short locals; a function named `buf`/`n` only collides when that
specific feature is also used. Those are lower priority and tracked separately.

## Success Criteria

- **SC-001**: `function w(n: i32): i32 { return n; }` with a sibling
  `function y(...)` and `console.log(w(1) + y(2))` -> `3`.
- **SC-002**: A batch of short-named functions (`w`, `y`, `q`, `z`, `b`) with a
  `console.log` referencing them compiles and prints the right sum.
- **SC-003**: `zig build` and `zig build test` stay green.

# Spec 139: user function names no longer collide with the runtime prelude

## Goal

Let a program define a top-level function with a short, common name —
`function f(...)`, `function s(...)`, `function i(...)`, `function c(...)`, ...
— without the build failing. Previously these produced a Zig
`capture shadows declaration of 'f'` error and never ran.

```ts
function f(x: i32, y: i32 = 10): i32 { return x + y; }
console.log(f(5));   // 15  (previously: failed to build native binary)
```

## Root cause

Every generated program prepended the regex runtime engine verbatim. That
engine contains inner captures and locals with short names (`for (flags) |f|`,
plus `p`, `s`, `i`, `c`, `e`, `r`, `v`, ...). Zig forbids an inner capture from
shadowing an enclosing declaration, so any user top-level function sharing one
of those names failed to compile — even in programs that never used a regex.
The `parseInt`/`parseFloat` helpers added in spec 135 had the same problem with
their own bare locals (`s`, `i`, `c`, `d`).

## Fix

1. **Gate the regex runtime**: emit `__LumenRegExp` and the regex engine only
   when the program actually uses a regex literal (`program.uses_regex`, set
   when the checker types a `.regex` node). Programs without regex — the vast
   majority — no longer carry those colliding names.
2. **Namespace the parse helpers**: rewrite `__parseInt`/`__parseFloat` locals
   with the reserved `__` prefix (`__s`, `__i`, `__ch`, ...) so they can never
   shadow a user identifier.

## Requirements

- **FR-001**: A top-level function named `f`, `s`, `i`, `c`, `v`, `flags`, etc.
  compiles and runs.
- **FR-002**: Programs that use a regex literal still compile and the regex
  runtime is emitted for them.
- **FR-003**: `parseInt`/`parseFloat` behavior is unchanged.

## Success Criteria

- **SC-001**: `function f(x: i32, y: i32 = 10): i32 { return x + y; }` with
  `f(5)` -> `15` and `f(5, 20)` -> `25`.
- **SC-002**: `function s(a: i32): i32 { return a; }` compiles and runs; likewise
  for `i`, `c`, `v`, `flags`.
- **SC-003**: `const re = /ab+c/; re.test("abbc")` -> `true`.
- **SC-004**: `zig build` and `zig build test` stay green.

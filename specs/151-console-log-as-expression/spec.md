# Spec 151: console.log as a void expression

## Goal

Allow `console.log(x)` (and `.info`/`.debug`/`.error`/`.warn`/`.trace`) to be
used as an expression, so it works inside an arrow-function body — the common
callback-logging pattern:

```ts
[1, 2, 3].forEach(x => console.log(x));
words.forEach(s => console.log(s));
```

Previously `console.*` was only a statement; inside an arrow body it parsed as a
method call on an undefined variable `console` and reported
`undefined variable 'console'`.

## Why additive, not breaking

The statement form of `console.*` is unchanged. This only adds an expression
form, which yields `void` — usable exactly where a void callback body is
expected.

## Semantics

`console.log(x)` as an expression prints `x` (single argument, same formatting as
the statement form: `log`/`info`/`debug` to stdout, `error`/`warn`/`trace` to
stderr with the same prefixes) and evaluates to `void`. A local binding named
`console` still shadows it. The argument must be a string, number, or boolean.

## Requirements

- **FR-001**: `console.log(x)` / `.info` / `.debug` / `.error` / `.warn` /
  `.trace` are valid void expressions.
- **FR-002**: Used as an arrow body, the arrow's return type is `void`, matching
  a `forEach` callback.
- **FR-003**: Exactly one argument, of a printable type (string/number/boolean);
  otherwise `E_ARG_COUNT` / `E_TYPE_MISMATCH`.
- **FR-004**: The statement form is unchanged.

## Success Criteria

- **SC-001**: `[1,2,3].forEach(x => console.log(x))` prints `1`, `2`, `3`.
- **SC-002**: `["a","b","c"].forEach(s => console.log(s))` prints `a`, `b`, `c`;
  `arr.forEach(x => console.log(x * 10))` prints the scaled values.
- **SC-003**: `console.log(...)` / `console.error(...)` statements still work.
- **SC-004**: `zig build` and `zig build test` stay green.

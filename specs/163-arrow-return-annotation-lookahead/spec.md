# Spec 163: arrow functions with a return-type annotation

## Goal

Recognize an arrow function that carries an explicit return-type annotation in
expression position:

```ts
const fn = (x: i32): i32 => x * 2;
const add = (a: i32, b: i32): i32 => a + b;
const greet = (name: string): string => "hi " + name;
```

Previously such an arrow was a syntax error whenever the parser needed its
arrow-lookahead to recognize it (e.g. on the right-hand side of an assignment):
the lookahead checked for `=>` immediately after the `)` and did not skip the
`: R` return annotation.

## Why additive, not breaking

Only makes previously-rejected programs parse. Arrows without a return
annotation, and arrows already recognized without lookahead, are unchanged.

## Semantics

The arrow-lookahead now skips an optional `: <type>` return annotation between
the parameter list's `)` and the `=>`, so `(params): R => body` is recognized as
an arrow. The annotation is checked as before (the body's type must match `R`).

## Requirements

- **FR-001**: `(params): R => body` is recognized as an arrow in expression
  position (e.g. `const f = (x: i32): i32 => ...`).
- **FR-002**: Arrows without a return annotation are unchanged.

## Success Criteria

- **SC-001**: `const fn = (x: i32): i32 => x * 2; fn(21)` -> `42`.
- **SC-002**: `const add = (a: i32, b: i32): i32 => a + b; add(3, 4)` -> `7`.
- **SC-003**: `const noRet = (x: i32) => x + 1; noRet(5)` -> `6` (no annotation
  unchanged).
- **SC-004**: `zig build` and `zig build test` stay green.

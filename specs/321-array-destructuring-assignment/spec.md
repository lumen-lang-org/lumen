# Spec 321 — Array destructuring assignment

## Goal

Support assigning to existing variables through an array pattern, most commonly a
swap:

```ts
let a = 1, b = 2;
[a, b] = [b, a];        // a = 2, b = 1
```

It also works from any array or tuple source:

```ts
let x = 0, y = 0;
const src: i32[] = [7, 8];
[x, y] = src;           // x = 7, y = 8
```

## Motivation

Only destructuring *declarations* (`const [a, b] = …`) were supported; a
destructuring *assignment* to existing variables failed to parse
(`expected ';', found '='`). Swaps and multi-assignment are common.

## Behavior

- `[t0, t1, …] = expr;` assigns each element of the (array or tuple) source to the
  corresponding existing variable.
- Targets must be simple, already-declared, mutable (`let`) variables; a `const`
  target or an unknown name is a clear error.
- The source is evaluated into a temporary first, so a swap reads the old values.
- Each element type must match the target's declared type.
- Nested patterns, rest elements, and member targets (`obj.x`) are not supported.

## Implementation

- `src/lumen_ast.zig`: `DestructureDecl` gains `is_assignment`.
- `src/lumen_parser.zig`: an array expression at statement position followed by
  `=` becomes a destructuring assignment whose targets are the array's
  variable elements.
- `src/lumen_check_stmt.zig`: assignment targets are resolved as existing mutable
  bindings, element types are checked, and each target is marked reassigned so it
  emits as `var`.
- `src/lumen_emit_stmt.zig`: an assignment binding emits `target = src[i];`
  (or the tuple positional field) instead of a new `const`.

## Verification

- `zig build` and `zig build test` green.
- A swap, an array/tuple source reassignment, a string swap, and a
  Fibonacci-style in-loop update run correctly; a `const` target and an unknown
  target error clearly; array-literal expression statements and destructuring
  declarations are unaffected.

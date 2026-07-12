# Spec 310 — Return-type inference for functions

## Goal

Let a function omit its return annotation and have the compiler infer the type
from the body, the way TypeScript does:

```ts
function add(a: i32, b: i32) { return a + b; }   // inferred: i32
function even(n: i32) { return n % 2 === 0; }    // inferred: bool
```

## Motivation

Previously an omitted return annotation defaulted to `void`, so any
value-returning function without an explicit `: T` failed with a confusing
`type mismatch: expected `void`, got `i32``. This also mis-reported unrelated
constructs (e.g. a `switch` with fall-through cases) because they sit in
un-annotated functions.

## Behavior

- A function with no return annotation infers its return type from the first
  value-carrying `return <expr>` in the body (searching nested blocks, `if`,
  loops, `switch`, and `try`).
- All other `return`s are then checked against the inferred type, so
  inconsistent returns are a clear error:
  `function bad(n: i32) { if (n>0) return 1; return "x"; }` reports
  `expected `i32`, got `string``.
- A function that never returns a value stays `void`.
- `async` functions still require an explicit `Promise<...>` return type.

### Inference limits

Inference runs in the declaration pass (so call sites see the inferred type),
before type aliases and function bodies are checked and without local scopes.
It therefore does not yet cover a return whose expression uses a loop/local
binding, a forward-referenced function, or a record type. Those cases now report
an actionable message —
`could not infer this function's return type — add an explicit `: T` return
annotation` — instead of the old `expected `void`` mismatch.

## Implementation

- `src/lumen_ast.zig`: `FunctionDecl` gains `infer_return`.
- `src/lumen_parser_decl.zig`: `infer_return` is set when the `: T` annotation is
  absent.
- `src/lumen_check_stmt.zig`: `firstReturnExpr` finds the first value return;
  `checkFunctionBody` flags an un-inferable function; the `return` check emits
  the annotate-guidance for that case.
- `src/lumen_check.zig`: `declareFunction` infers the return type from the first
  return expression (params in a temporary scope) when `infer_return` is set.

## Verification

- `zig build` and `zig build test` green.
- Arithmetic/comparison/array/literal/earlier-call returns infer and run;
  inconsistent returns error clearly; void functions unchanged; async still
  requires an annotation; un-inferable returns get the guidance message.

# Spec 314 — Return inference for local-binding returns

## Goal

Complete return-type inference (specs 310–313) so it also covers returns built
from body-local bindings, loop variables, and locally-declared functions:

```ts
function sum(...xs: i32[]) {
  let total = 0;
  for (const x of xs) total = total + x;
  return total;                 // inferred: i32
}
```

## Motivation

The declaration-pass inference could only see parameters, so a `return` of a
local variable fell back to the "add an annotation" guidance. Accumulator loops
and helper-local functions are common enough that this deserved real inference.

## Behavior

When an un-annotated function/method/arrow's return type cannot be determined in
the declaration pass, the type is now collected while the body is checked (where
locals, loop variables, and earlier declarations are all in scope):

- Each value `return` records its type; the first fixes the inferred type and
  the rest must agree (a mismatch is a clear `expected/got` error).
- The inferred type is written back to the declaration and the `funcs` table, so
  call sites **after** the definition observe it.
- All-paths-return is still enforced.

### Remaining limit

A call to an un-annotated function placed **before** its definition is still
checked against `void` (the body has not been inferred yet) and reports
`a void expression cannot be used as a value`. Define the function first, or add
an explicit return annotation.

## Implementation

- `src/lumen_check.zig`: a `collected_return` checker field accumulates returned
  value types during an un-inferable body check.
- `src/lumen_check_stmt.zig`: in inference mode the `return` check records the
  value type instead of erroring; `checkFunctionBody` finalizes the collected
  type onto the decl and `funcs` entry and enforces all-paths-return.
- `src/lumen_check_expr.zig`: block-body arrows adopt the collected type after
  their body is checked.

## Verification

- `zig build` and `zig build test` green.
- Accumulator loops, `const b = …; return b;`, a returned loop variable, and a
  returned local arrow all infer and run; inconsistent returns error clearly;
  a forward-referenced un-annotated call reports the documented message.

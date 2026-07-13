# 408 — `boolean.toString()`

## Problem

Calling `.toString()` on a boolean failed type-checking:

```ts
const b = true;
b.toString();       // error: type mismatch [E_TYPE_MISMATCH]
(x > 3).toString(); // error
```

Method-call dispatch had handlers for arrays, strings, numbers, and the
container types, but no `boolean` receiver case, so any method on a `bool` fell
through to a generic mismatch. Booleans already rendered correctly in templates
and string concatenation; only the explicit method was missing.

## Approach

- **AST** (`lumen_ast.zig`): add a `bool_method` flag to the method-call node.
- **Check** (`lumen_check_expr.zig`): add a `bool` receiver branch — `toString()`
  (zero args) returns `string`; any other method reports a clean
  "`boolean` has no method '<name>'" via `failUnknownMethod`.
- **Emit** (`lumen_emit.zig`): lower `b.toString()` to
  `if (b) "true" else "false"` typed as `[]const u8`.

## Verification

- `true.toString()` → `true`; `false.toString()` → `false`.
- `(x > 3).toString()` → `true`.
- `"val: " + b.toString()` → `val: true`.
- Unknown bool method reports `` `boolean` has no method 'foo' ``.
- Number `toString`, templates, and concatenation unchanged.
- Full `zig build` + test suite green.

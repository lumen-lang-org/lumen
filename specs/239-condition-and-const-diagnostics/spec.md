# Spec 239: truthiness and const-assignment diagnostics

## Goal

Two more high-frequency errors explain the fix:

```text
main.ts:2:1: error: `if` condition must be `boolean`, got `i32` —
truthiness is not supported; write `x != 0`
main.ts:2:1: error: `while` condition must be `boolean`, got `string` —
truthiness is not supported; write `s != ""` or `s.length > 0`
main.ts:3:1: error: `if` condition must be `boolean`, got `string | null` —
truthiness is not supported; write `x != null`
main.ts:2:1: error: cannot assign to 'x' — it was declared with `const`;
use `let x = ...` to make it mutable
```

Previously all of these were a bare "type mismatch" / "cannot assign to a
'const' binding" with no type, no name, and no suggested fix.

## Semantics

- Non-boolean conditions in `if`, `while`, `do-while`, `for`, and `?:` report
  the construct, the actual type (TS syntax), and a fix suggestion picked by
  type: numeric `x != 0`, string `s != ""` / `s.length > 0`, nullable
  `x != null`, array `a.length > 0`, otherwise "an explicit comparison".
- Assigning (or `++`/`--`) to a `const` binding names the binding and points
  at `let`.

## Success Criteria

- **SC-001**: `if (n)` on i32, `while (s)` on string, and `if (r)` on
  `string | null` each report the tailored message.
- **SC-002**: `x = 2` and `k++` on const bindings name the variable.
- **SC-003**: Boolean conditions still check clean; `zig build` and
  `zig build test` stay green.

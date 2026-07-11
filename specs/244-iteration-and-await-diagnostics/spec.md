# Spec 244: iteration, destructuring, and missing-await diagnostics

## Goal

```text
main.ts:2:1: error: `for...of` needs an array, string, or Map — got `i32`
main.ts:2:1: error: `for...in` needs a record or array, got `Map<string, i32>`
— to iterate values use `for...of`
main.ts:2:1: error: destructuring pattern has 3 names but `[i32, string]` has
2 elements
main.ts:2:1: error: array destructuring needs an array or tuple, got `string`
main.ts:4:7: error: type mismatch: expected `i32`, got `Promise<i32>` — did
you forget `await`?
```

Previously all of these were a bare "type mismatch".

## Semantics

- `for...of`/`for...in` on an unsupported iterable name the actual type and
  what the construct accepts; `for...in` points at `for...of` for values.
- Tuple destructuring arity mismatches report both counts; a mismatched
  pattern still binds the names that line up (error recovery), so later uses
  don't cascade into "undefined variable" noise. Non-array sources name the
  actual type.
- Any type mismatch whose actual type is `Promise<T>` with `T` being exactly
  the expected type appends "did you forget `await`?" (applies everywhere
  failTypeMismatch is used: declarations, arguments, returns).

## Success Criteria

- **SC-001**: Each probe above produces the tailored message.
- **SC-002**: `const [a, b, c] = pair` (2-tuple) reports only the arity error
  — no follow-on undefined-variable errors for `a`/`b`.
- **SC-003**: `zig build` and `zig build test` stay green.

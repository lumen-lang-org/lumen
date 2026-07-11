# Spec 273: inner diagnostics survive outer inference failures

## Goal

```ts
items.forEach((item: string, i: i32): void => {
  acc += String(i) + item        // ← the real error, now reported here
})
```

now reports `cannot mutate a variable captured by an arrow function — use a
`for...of` loop or `reduce` instead` at the assignment line. Previously the
enclosing expression statement clobbered it with "cannot infer expression
type" at the statement head.

## Semantics

`inferenceFail` keeps an already-recorded diagnostic whenever it points at
the same or a later line (checking is top-down, so such an error came from
this statement's own subexpressions) instead of only the exact same
position. E_CAPTURED_MUTATION's humanized text now names the alternatives.

## Success Criteria

- **SC-001**: The forEach probe reports the captured-mutation error at the
  mutation line.
- **SC-002**: Genuine inference failures (no inner error) report as before;
  `zig build` and `zig build test` stay green.

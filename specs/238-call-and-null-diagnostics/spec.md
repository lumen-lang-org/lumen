# Spec 238: precise argument-count and possibly-null diagnostics

## Goal

Two frequent errors now explain themselves:

```text
main.ts:4:1: error: 'add' expects 2 arguments, got 1
main.ts:4:1: error: 'greet' expects 1-2 arguments, got 0
main.ts:5:7: error: constructor of 'P' expects 1 argument, got 2
main.ts:6:1: error: 'r' (`string | null`) may be null — check `!= null`
before reading '.length', or use optional chaining `?.length`
```

Previously these reported "wrong number of arguments" (no counts, no name)
and — for a property read on a `T | null` value — the unrelated "cannot infer
console.log argument type" or a bare "type mismatch".

## Semantics

- The shared call-argument checker takes the callee's display name and renders
  `expects N argument(s)` (exact), `expects N-M arguments` (defaults/optional
  params), or `expects at least N argument(s)` (rest param), plus the actual
  count. Covers user function calls and class constructors.
- A field read on a `T | null` value names the variable (when it is one), the
  full type, and both idiomatic fixes (`!= null` narrowing, `?.` chaining).
  A method call on a `T | null` receiver gets the same message with the
  narrowing fix only (optional-chained calls are not supported).
- Assignability checks no longer overwrite a detailed inner diagnostic at the
  same position with a generic "type mismatch" (`inferenceFail` guard), so the
  constructor message above survives through `const p: P = new P(1, 2)`.

## Success Criteria

- **SC-001**: Wrong arg counts on functions, defaulted functions, and
  constructors each report name + expected/actual counts.
- **SC-002**: `.length` read and `.toUpperCase()` call on `string | null`
  report the may-be-null guidance, not an inference error.
- **SC-003**: Plain type mismatches are unchanged; `zig build` and
  `zig build test` stay green.

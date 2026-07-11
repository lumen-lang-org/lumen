# Spec 266: exhaustive literal-union switches + literal-union ASI

## Goal

```ts
type Grade = "A" | "B" | "C"        // no trailing `;` needed now (ASI)
function points(g: Grade): i32 {
  switch (g) {
    case "A": return 4
    case "B": return 3
    case "C": return 2
  }                                  // exhaustive: no default required
}
```

Previously the semicolon-less union declaration was a bare "syntax error",
and the exhaustive switch reported "not all code paths return a value".

## Semantics

- String/int literal-union `type` declarations end at ASI boundaries like
  every other statement.
- A default-less switch over a string-literal union whose cases cover every
  member counts as returning on all paths; emission appends
  `else unreachable` (the checker proved the fall-through impossible).
  A switch missing a member still requires a default / trailing return.

## Success Criteria

- **SC-001**: The program above compiles and runs for every grade.
- **SC-002**: Dropping one case brings back E_MISSING_RETURN.
- **SC-003**: `zig build` and `zig build test` stay green.

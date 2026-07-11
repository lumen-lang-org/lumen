# Spec 250: unreachable code warns and compiles

## Goal

```text
main.ts:3:3: warning: unreachable code
  3 |   console.log("never")
```

and the program still builds and runs. Previously statements after an
unconditional `return`/`throw`/`break`/`continue` produced no warning and —
worse — were emitted into the generated Zig, which rejects dead code, so the
build failed with a "likely a Lumen compiler bug" backend report.

## Semantics

- The checker warns once per block at the first statement that follows an
  unconditional `return`, `throw`, `break`, or `continue` (function bodies
  and every nested block).
- Emission drops the dead statements (`emitBody` stops after a diverging
  statement), so the generated code always compiles. Applies to function
  bodies, methods, constructors, loops, if/else branches, switch cases,
  test blocks, and bare blocks.

## Success Criteria

- **SC-001**: Code after `return` in a function and after `continue` in a
  loop warns and runs (exit 0).
- **SC-002**: Reachable code is unaffected; `zig build` and `zig build test`
  stay green.

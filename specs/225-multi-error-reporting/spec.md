# Spec 225: multiple errors per compile

## Goal

Report several independent errors in one run instead of stopping at the first:

```text
g.ts:1:7: error: type mismatch: expected `i32`, got `string`
  1 | const a: i32 = "one"
    |       ^

g.ts:2:7: error: type mismatch: expected `string`, got `i32`
  2 | const b: string = 2
    |       ^

g.ts:3:1: error: undefined variable 'missing'
  3 | console.log(missing)
    | ^

3 errors
```

Previously the first checker error aborted the compile, forcing a fix-recompile
cycle per error.

## Semantics

- The checker's top-level statement pass continues past a failed statement,
  recording each diagnostic (deduplicated by position) up to a cap of 5 —
  later errors are increasingly likely to be cascades.
- A single error renders exactly as before; multiple errors render one block
  each plus an `N errors` summary line.
- **Error recovery**: a variable declaration whose initializer mismatches its
  annotation still binds the name with the declared type, so later uses don't
  cascade into `undefined variable` noise (`const x: i32 = "bad"` followed by
  `x + 1` reports exactly one error).
- Parse errors still stop at the first (the parser has no recovery); codegen
  never runs when any error was recorded.

## Implementation

`Diag` gains an `extra: []const Diag` list; the checker collects into
`all_diags` and surfaces first + rest; the CLI printer renders all.
Public compile APIs are signature-compatible.

## Success Criteria

- **SC-001**: Three independent bad statements report three located errors and
  `3 errors`.
- **SC-002**: A failed declaration does not produce follow-on undefined-variable
  errors for its own name.
- **SC-003**: Single-error and valid programs behave exactly as before;
  `zig build` and `zig build test` stay green.

# Spec 203: bare block statements

## Goal

Support a bare `{ ... }` block as a statement — a nested lexical scope:

```ts
const x = 1;
{
  const x = 2;   // shadows the outer x within the block
  console.log(x); // 2
}
console.log(x);   // 1
```

Previously a `{` at statement position was a syntax error.

## Why additive, not breaking

Only makes previously-rejected programs compile. A `{` at statement position is
a block, never an object literal (the JS/TS statement-position rule), so no
existing program changes meaning.

## Semantics

A bare block introduces a new lexical scope: bindings declared inside it shadow
outer ones and do not leak out. Control flow (`return`, `throw`, `break`,
`continue`) inside the block behaves as if the statements were written inline. A
block whose body returns on all paths counts toward a function's return check.

## Implementation

- AST: a `block_stmt` statement variant holding the inner statements.
- Parser: `{` at statement position parses a block.
- Checker: pushes a scope, checks the body, pops.
- Emit: wraps the body in a Zig `{ ... }`.
- Analysis passes updated to recurse into block bodies: return-path, throw
  detection, unused-parameter use-scan, and the string-builder / accumulator
  optimization (so an accumulator mutated inside a block is analyzed correctly).

## Requirements

- **FR-001**: A bare block runs its statements in a nested scope; inner bindings
  shadow and do not leak.
- **FR-002**: `return`/`throw` inside a block work (a returning block satisfies
  the function return check; a throw is caught by an enclosing try).
- **FR-003**: A parameter or accumulator used only inside a block is handled
  correctly (no spurious unused-parameter or miscompiled-builder errors).

## Success Criteria

- **SC-001**: `const x=1; { const x=2; console.log(x); } console.log(x)` prints
  `2` then `1`.
- **SC-002**: `function f(n){ { return n*2; } }` returns `n*2`; a throw inside a
  block is caught by an enclosing try.
- **SC-003**: `let s=""; { for(...) s += "*"; } return s;` builds the string
  correctly.
- **SC-004**: `zig build` and `zig build test` stay green.

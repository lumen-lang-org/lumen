# Spec 161: fix postfix ++/-- statement regressed by spec 156

## Goal

Fix a regression from spec 156: a postfix increment/decrement statement (`i++;`,
`x--;`) failed to parse.

```ts
let i = 5;
i++;        // spec 156 made this a syntax error
```

## Root cause

Spec 156 routed identifier-led statements that are not assignments to a general
expression-statement parse. But postfix `++`/`--` are not handled by the
expression parser (they are lowered through the assignment path), so `i++;`
rewound to `parseExpr`, which consumed `i` and then choked on `++`.

## Fix

Treat a following `++`/`--` as an assignment-style statement (its existing
lowering) instead of routing to the expression parser. The general
expression-statement fallback still applies to genuine operator continuations
(`x > 0 ? ...`, `x + y;`).

## Requirements

- **FR-001**: `i++;` and `x--;` parse as statements.
- **FR-002**: `i++` inside `do`/`while`/`for` bodies works.
- **FR-003**: Ternary-as-statement (spec 156) still works.

## Success Criteria

- **SC-001**: `let i = 5; i++;` gives `i == 6`; `let x = 10; x--;` gives
  `x == 9`.
- **SC-002**: `do { j++; } while (j < 3);` and `while (k < 3) { k++; }` run.
- **SC-003**: `cond ? console.log("yes") : console.log("no");` still works.
- **SC-004**: `zig build` and `zig build test` stay green.

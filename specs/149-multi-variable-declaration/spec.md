# Spec 149: multi-variable declarations

## Goal

Allow several comma-separated declarators in one `let`/`const`/`var` statement,
as in JavaScript/TypeScript:

```ts
let a = 1, b = 2, c = 3;
const x = "hi", y = "there";
let i: i32 = 0, j: i32 = 10;
```

Previously only a single declarator per statement was accepted; a comma reported
a syntax error.

## Why additive, not breaking

Only makes previously-rejected programs compile. A single-declarator statement
parses to the same `var_decl` node as before.

## Semantics

Each declarator is independent: it may carry its own type annotation and
initializer, and each binds in the enclosing scope (no new block scope is
introduced). A statement with one declarator stays a `var_decl`; two or more
become a `var_decl_group` that checks and emits each declarator in order,
identically to writing separate statements.

## Requirements

- **FR-001**: `let a = 1, b = 2;` declares both `a` and `b` in the current
  scope.
- **FR-002**: Each declarator may be independently annotated
  (`let i: i32 = 0, j: i32 = 10;`).
- **FR-003**: `const` groups and reassignment tracking (`let`) behave per
  declarator, exactly as separate statements would.
- **FR-004**: A single-declarator statement is unchanged.

## Success Criteria

- **SC-001**: `let a = 1, b = 2, c = 3; a + b + c` -> `6`.
- **SC-002**: `const x = "hi", y = "there"; x + " " + y` -> `hi there`.
- **SC-003**: `let i: i32 = 0, j: i32 = 10; i = i + 5; i + j` -> `15`.
- **SC-004**: A grouped string accumulator (`let s = "", count = 0;` then `+=`
  in a loop) works.
- **SC-005**: `zig build` and `zig build test` stay green.

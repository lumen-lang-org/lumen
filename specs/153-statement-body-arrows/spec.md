# Spec 153: statement-body arrow functions

## Goal

Support arrow functions with a `{ ... }` statement body, the common form for
multi-statement callbacks:

```ts
[1, 2, 3, 4, 5].forEach(n => {
  if (n % 2 === 0) {
    console.log(n);
  }
});
words.forEach(w => {
  const upper = w.toUpperCase();
  console.log(upper + "!");
});
```

Previously an arrow body had to be a single expression; `=> { ... }` was a
syntax error.

## Why additive, not breaking

Only makes previously-rejected programs compile. Expression-body arrows
(`x => x * 2`) are unchanged.

## Semantics

A statement-body arrow has a **void** body: the block runs for its side effects
and the arrow's return type is `void`, matching a `forEach` callback. Local
declarations, `if`/`for`/`while`, method calls, and `console.log` inside the
block all work, and the block may reference (read) outer bindings, which are
captured.

### Constraints (rejected with a compile error, not broken output)
- **Value returns are out of scope**: a `return <value>;` inside a statement
  body is rejected. For a value-producing callback (`map`, `filter`, `reduce`,
  ...), use an expression body (`x => x * 2`).
- **No mutation of captured outer variables**: assigning to a variable declared
  outside the arrow (`count += n`) is rejected (`E_CAPTURED_MUTATION`), because
  captures are by value. Use `reduce` for accumulation.

## Requirements

- **FR-001**: `(params) => { statements }` and the bare `p => { statements }`
  form parse and type-check as void-bodied arrows.
- **FR-002**: The block may read outer bindings (captured) and declare its own
  locals.
- **FR-003**: Assigning to a captured outer variable inside the block is a
  compile error.
- **FR-004**: Expression-body arrows are unchanged.

## Success Criteria

- **SC-001**: `nums.forEach(n => { if (n % 2 === 0) console.log(n); })` prints
  the even elements.
- **SC-002**: A block body with a local (`const upper = w.toUpperCase();`) and a
  `console.log` runs correctly.
- **SC-003**: `nums.map(n => n * 2)` (expression body) still works.
- **SC-004**: `count += n` inside a statement-body arrow is a compile error, not
  a broken build.
- **SC-005**: `zig build` and `zig build test` stay green.

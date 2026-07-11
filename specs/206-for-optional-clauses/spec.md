# Spec 206: optional clauses in a C-style for loop

## Goal

Allow any of the three C-style for clauses to be omitted:

```ts
for (; i < 3; i++) { ... }   // no init
for (let i = 0; i < 3; ) { ... i++; }  // no update
for (let i = 0; ; i++) { if (...) break; }  // no condition
for (;;) { if (...) break; }  // infinite loop
```

Previously all three clauses were required; omitting any was a syntax error.

## Why additive, not breaking

Only makes previously-rejected programs compile. A full `for (init; cond;
update)` and multi-declarator / multi-update forms are unchanged.

## Semantics

- Omitted init: no initializer runs.
- Omitted condition: the loop runs unconditionally (equivalent to `true`); exit
  via `break`/`return`.
- Omitted update: no update step runs each iteration.

`continue` still jumps to the update step (when present), matching JS.

## Implementation

- AST: `init`, `cond`, and `update` on `ForStmt` are optional.
- Parser: a leading `;` skips the init; an empty condition or update slot leaves
  that clause null.
- Checker: skips checking an absent init/update; an absent condition is not
  type-checked (loops unconditionally).
- Emit: an absent init/update is omitted; an absent condition emits `true`; the
  Zig `while` continue-expression is emitted only when an update is present.
- Analysis/clone passes guard the now-optional clauses.

## Requirements

- **FR-001**: Each of init, condition, and update may be omitted independently.
- **FR-002**: An omitted condition loops unconditionally.
- **FR-003**: Full and multi-clause for loops are unchanged.

## Success Criteria

- **SC-001**: `for (; i<3; i++)` (external `i`) prints `0 1 2`.
- **SC-002**: `for (let i=0; i<3; )` with `i++` in the body prints `0 1 2`.
- **SC-003**: `for (;;) { n++; if (n>=5) break; }` yields `n = 5`;
  `for (let i=0; ; i++) { if (i>=3) break; ... }` prints `0 1 2`.
- **SC-004**: `for (let i=0,j=10; i<3; i++,j--)` is unchanged.
- **SC-005**: `zig build` and `zig build test` stay green.

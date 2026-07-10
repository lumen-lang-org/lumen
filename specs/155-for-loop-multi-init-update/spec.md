# Spec 155: multiple init/update clauses in a for loop

## Goal

Allow comma-separated declarators in a C-style `for` loop's init clause and
comma-separated updates in its update clause, as in JavaScript:

```ts
for (let i = 0, n = 5; i < n; i++) console.log(i);
for (let i = 0, len = arr.length; i < len; i++) sum += arr[i];
for (let i = 0, j = 3; i < j; i++, j--) { ... }
```

Previously only a single init declarator and a single update were accepted; a
comma reported a syntax error.

## Why additive, not breaking

Only makes previously-rejected programs parse. A single-init, single-update loop
is unchanged.

## Semantics

- **Init**: the first declarator plus any comma-separated extras all bind in the
  loop scope, each with its own optional annotation and initializer.
- **Update**: the first update plus any comma-separated extras all run at the end
  of each iteration, in order (lowered to a Zig block continue-expression).

The loop variable(s) that a comma-update mutates emit as `var`.

## Requirements

- **FR-001**: `for (let i = 0, n = 5; ...)` declares both `i` and `n` in the loop
  scope.
- **FR-002**: `for (...; ...; i++, j--)` runs both updates each iteration.
- **FR-003**: A single-init, single-update loop is unchanged.

## Success Criteria

- **SC-001**: `for (let i = 0, n = 5; i < n; i++) console.log(i);` prints
  `0`..`4`.
- **SC-002**: `for (let i = 0, len = arr.length; i < len; i++) sum += arr[i];`
  sums the array.
- **SC-003**: `for (let i = 0, j = 3; i < j; i++, j--)` iterates with both
  counters advancing (`i=0,j=3` then `i=1,j=2`).
- **SC-004**: `zig build` and `zig build test` stay green.

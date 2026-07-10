# Spec 164: increment / decrement as expressions

## Goal

Support `++`/`--` in expression position, returning a value, as in
JavaScript/TypeScript:

```ts
const a = x++;      // a = old x, x incremented
const b = ++y;      // b = new y
console.log(arr[i++]);  // index with i, then increment
while (n-- > 0) { ... }
```

Previously `++`/`--` were only recognized as statements (`i++;`) and as `for`
loop updates; using them for their value (`x++` inside an expression) was a
syntax error.

## Why additive, not breaking

Only makes previously-rejected programs parse. Statement `i++;` and `for` loop
updates are unchanged (they keep their existing assignment lowering).

## Semantics

- **Prefix** `++x` / `--x`: increments/decrements `x`, then evaluates to the new
  value.
- **Postfix** `x++` / `x--`: evaluates to the old value, then
  increments/decrements `x`.

The target must be a mutable numeric variable; a `const` target reports
`E_CONST_ASSIGNMENT` and a non-numeric target `E_TYPE_MISMATCH`. The target is
marked reassigned so it emits as `var`.

## Requirements

- **FR-001**: `x++` / `x--` in expression position evaluate to the old value and
  update `x`.
- **FR-002**: `++x` / `--x` evaluate to the new value and update `x`.
- **FR-003**: The target must be a mutable numeric variable.
- **FR-004**: Statement `i++;` and `for` loop updates are unchanged.

## Success Criteria

- **SC-001**: `let x = 5; const a = x++;` gives `a == 5`, `x == 6`.
- **SC-002**: `let y = 10; const b = ++y;` gives `b == 11`, `y == 11`.
- **SC-003**: `arr[i++]` reads `arr[i]` then increments `i`;
  `while (n-- > 0)` iterates with `n` decrementing.
- **SC-004**: `i++;` (statement) and `for (...; ...; j++)` still work.
- **SC-005**: `zig build` and `zig build test` stay green.

# Spec 199: `this.field++` / `this.field--`

## Goal

Allow postfix increment/decrement of a field through `this` as a statement:

```ts
class Counter {
  n: i32;
  constructor() { this.n = 0; }
  tick() { this.n++; }   // was a syntax error
}
```

Previously `this.x++` / `this.x--` was a syntax error; only `this.x += 1` worked.

## Why additive, not breaking

Only makes previously-rejected programs compile. `this.x = e`, `this.x += e`,
and other compound assignments through `this` are unchanged.

## Semantics

As a statement the postfix value is discarded, so `this.x++;` lowers to
`this.x += 1;` and `this.x--;` to `this.x -= 1;` — the field is incremented or
decremented in place. (Using `this.x++` as an expression value is not covered by
this spec; it is a statement-position form.)

## Requirements

- **FR-001**: `this.field++;` increments the field by 1.
- **FR-002**: `this.field--;` decrements the field by 1.
- **FR-003**: `this.field = e`, `this.field += e`, and method calls through
  `this` are unchanged.

## Success Criteria

- **SC-001**: A method calling `this.x++` twice takes `x` from 0 to 2.
- **SC-002**: `this.x--` from 5 yields 4.
- **SC-003**: A counter `tick() { this.n++; }` driven 5 times reads 5.
- **SC-004**: `this.x += 3` and `this.x = 9` still work.
- **SC-005**: `zig build` and `zig build test` stay green.

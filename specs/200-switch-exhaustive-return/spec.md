# Spec 200: a switch where every branch returns satisfies the return check

## Goal

Let a function end with a switch whose every branch returns, without a redundant
trailing `return`:

```ts
function classify(n: i32): string {
  switch (n) {
    case 0: return "zero";
    case 1: return "one";
    default: return "many";
  }
  // no trailing return needed
}
```

Previously this reported `E_MISSING_RETURN` — the return-path analysis did not
consider a switch, so a dead trailing `return` was required.

## Why additive, not breaking

Only makes previously-rejected programs compile. Functions that already returned
on all paths, and switches used for side effects, are unchanged.

## Semantics

A switch statement counts as returning on all paths when it has a `default`
clause whose body returns and every `case` clause has a body that returns. A
switch with no `default`, a non-returning `default`, or any empty
(fall-through) or non-returning case does not satisfy the check — the function
still needs a trailing return in those cases. (The empty-fall-through form is
treated conservatively rather than analyzed, to stay sound.)

## Requirements

- **FR-001**: A trailing switch with a returning `default` and every case
  returning satisfies the return check.
- **FR-002**: A switch without a `default`, or with a non-returning `default`
  or case, still requires a trailing return.

## Success Criteria

- **SC-001**: `switch(n){case 0:return...;case 1:return...;default:return...}`
  as the last statement compiles and returns correctly.
- **SC-002**: Works for a string discriminant.
- **SC-003**: A switch with a non-returning `default` still reports
  `E_MISSING_RETURN`.
- **SC-004**: `zig build` and `zig build test` stay green.

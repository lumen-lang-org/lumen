# Spec 260: guard-clause null narrowing

## Goal

The idiomatic early-return guard narrows for the rest of the function:

```ts
function len(s: string | null): i32 {
  if (s == null) return -1
  return s.length          // s: string here (was: may-be-null error)
}
```

Stacked guards compose (`if (s == null) throw ...` then `if (t == null)
return s` then `s + t`).

## Semantics

When an `if` has no else and its then-branch always exits (returns/throws
on every path), the condition's negative narrowing applies to the rest of
the enclosing block: `x == null` guards leave `x` narrowed non-null below,
exactly like spec 259's union complement. Entries are block-scoped
(cleared at the enclosing block's exit). `!= null` then-branch narrowing
is unchanged.

## Success Criteria

- **SC-001**: Block-body and single-line guards both compile; values and
  the null path behave correctly at runtime.
- **SC-002**: Stacked guards (throw + return) narrow cumulatively.
- **SC-003**: `zig build` and `zig build test` stay green.

# Spec 285: multi-level field-path narrowing

## Goal

Nested optional field access after a guard works:

```ts
type Outer = { inner: { val: string | null } }  // via named types
if (o.inner.val != null) {
  console.log(o.inner.val.length)   // o.inner.val: string here
}

function connect(c: Cfg): string {
  if (c.db.host == null) return "no host"
  return "connecting to " + c.db.host   // guard-clause narrowing, deep
}
```

Previously narrowing keys were limited to one level (`x` or `x.f`), so
`o.inner.val` stayed `string | null` and reported the may-be-null error.

## Semantics

`narrowPath` now walks an arbitrary field-access chain rooted at a variable
(`a.b.c`, dotted key), used by every narrowing site (if/else, ternary,
guard clauses, while, `&&`/`||`). Any non-plain segment — an index, a call,
or an optional-chain link — makes the whole path un-narrowable (re-reading
it may not be stable/side-effect-free). Emit unwraps the narrowed field
read with `.?` as before, now on the deeper access.

## Success Criteria

- **SC-001**: `o.inner.val` narrows in an if-body, an else-branch, a
  guard-clause return, and `??`.
- **SC-002**: A method call on the deep-narrowed value (`.toUpperCase()`)
  works.
- **SC-003**: `zig build` and `zig build test` stay green.

# Spec 443 — `push`/`unshift` on a class-field array

## Problem

Specs 441/442 desugared `push`/`unshift` on a **local** array variable. The same
call on a class-field array — the core of the builder / accumulator-object
pattern — was still rejected:

```ts
class Builder {
  private parts: string[] = [];
  add(s: string): Builder { this.parts.push(s); return this; } // error
}
```

## Change

The `expr_stmt` push/unshift desugar (`lumen_check_stmt.zig`) is generalized from
a local-variable receiver to any **pure** receiver:

- **Local array** (`a.push(x)`) → plain reassignment `a = [...a, x]`.
- **Class-field array** (`this.items.push(x)`, `obj.items.push(x)`, or a deeper
  `this.a.b.push(x)` chain over pure receivers) → a member assignment
  `this.items = [...this.items, x]`, but only after confirming the field's type
  is an array.

A new `clonePureRecv` helper deep-copies the receiver (`this` / variable /
field / index chain) so the reassignment target and its `[...recv, x]` value
don't share an AST node. An impure receiver (`f().items.push(x)`) or a non-array
field falls through to the normal check and its diagnostic.

## Verification

- `zig build` and `zig build test` clean.
- Builder pattern (`this.parts.push(s); return this;`) chains correctly →
  `a b c`.
- A `Stack` class using `this.items.push(x)` reports the right size and sum.
- `obj.items.push(x)` on an instance-variable field works.
- Local `push`/`unshift` (specs 441/442) and the `const` diagnostic are
  unchanged.

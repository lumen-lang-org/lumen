# 398 — arrow functions capture `this`

## Problem

An arrow function that read `this` inside a class method failed to compile —
the generated Zig referenced `self` from inside the arrow's own function, where
it is out of scope:

```ts
class C {
  base = 100;
  addAll(a: number[]): number[] { return a.map(x => x + this.base); }
}
```

produced `error: 'self' not accessible from inner function`. This blocked the
single most common closure pattern in class code: `map` / `filter` / `forEach`
(and any callback) whose body reaches instance state through `this`.

## Approach

Treat `this` as a captured binding, reusing the existing arrow closure-env
mechanism (which already carries captured locals into a heap `Env` struct).

- **`Capture`** (`lumen_ast.zig`): add an `is_this` flag.
- **Check** (`lumen_check_expr.zig`, `this_expr`): when inside an arrow body
  (`current_captures` is set), record a single `self` capture typed as the
  instance's `class_type`. The env then carries `self: *C` and initializes it
  from the enclosing method's `self`.
- **Emit** (`lumen_emit.zig`, `this_expr`): inside an arrow body
  (`g_cur_arrow_env != 0`) read the instance pointer from the closure env
  (`__env<id>.self`); in a plain method body emit the `self` parameter directly.
- **`this`-usage analysis** (`lumen_emit_analysis.zig`, `exprUsesThis`): a
  statement-body arrow (`=> { ... }`) now recurses into its block, so a method
  whose only `this` use is inside such an arrow is no longer wrongly given a
  `_ = self;` discard (which collided with the env's `.self = self` read).

## Verification

- `a.map(x => x + this.base)` → `101,102,103`; `filter`, `forEach` likewise.
- Expression-body and statement-body arrows: `() => this.v`,
  `() => { return this.v + 1; }`, `() => this.method()` all work.
- Mixed capture (`() => this.v + k` with a captured local) → correct.
- Plain method `this` access and the full test suite are unchanged (green).

## Known limitation

An arrow nested **inside another arrow** that reaches `this` (two closure levels)
still fails to compile. This is the same pre-existing deep-capture limitation
that affects any runtime local captured through an intermediate arrow
(`() => { const g = () => k; ... }` with a runtime `k`), not something specific
to `this`. Single-level method→callback capture — the common case — is fully
supported.

# Spec 277: `this.` chain statements + generic containers in generic classes

## Goal

```ts
class Registry<T> {
  items: Map<string, T>
  constructor() { this.items = new Map<string, T>() }
  register(key: string, v: T): void { this.items.set(key, v) }
  lookup(key: string): T | null { return this.items.get(key) }
}
```

Two independent fixes this pattern needed:

- `this.items.set(key, v)` as a statement was a parse error — statement
  position only handled `this.field` followed by a call, `++/--`, or `=`.
  Deeper chains (`this.a.b(...)`, `this.a.b.c = v`, `this.arr[i] = v`) now
  parse via the general postfix path, ending as an expression statement or
  a nested member assignment.
- `new Map<string, T>()` inside a generic class body kept the literal `T`
  through specialization (yielding "expected `Map<string, i32>`, got
  `Map<string, T>`"): explicit type arguments on `new` are now substituted
  like every other annotation.

## Success Criteria

- **SC-001**: The Registry probe (single-line and multi-line bodies)
  compiles and runs; hits and misses behave (`1 -1`).
- **SC-002**: Non-generic `this.` chains work the same.
- **SC-003**: `zig build` and `zig build test` stay green.

# 370 — Nested arrow functions (curried closures) compile

## Problem

A curried arrow — an arrow returning another arrow — failed to compile:

```ts
const add = (a: i32) => (b: i32) => a + b;
// error: function parameter '__ctx' shadows function parameter from outer scope
```

Each arrow lowers to an inline `struct { fn __afn(__ctx: *const anyopaque, ...) }`.
When one arrow is emitted inside another's body, both used the same fixed helper
names — the `__ctx` parameter, the `__env` capture pointer, the `Env` struct,
the `__e` allocation, and the `blk` label. Zig rejects a parameter or label that
shadows an enclosing one, so the inner `__afn`'s `__ctx` collided with the
outer's.

## Change

`lumen_emit.zig`: each arrow gets a unique id (`g_arrow_seq`) that suffixes all
of its helper names — `__ctx{id}`, `__env{id}`, `Env{id}`, `__e{id}`, and the
`blk{id}` label. A module var `g_cur_arrow_env` tracks the id of the arrow whose
body is currently emitting, so a captured binding reads from the right
`__env{id}`. Non-nested arrows are unaffected (they just carry a numeric
suffix now).

## Verified

`zig build` + `zig build test` green. Probes:

- `const add = (a) => (b) => a + b; add(3)(4)` → `7` (the reported case).
- `const mk = () => (x) => x * 2; mk()(5)` → `10` (nested, no capture).
- `[1,2,3].map(n => (x) => x + n)` — an arrow returned from a `.map` callback,
  each capturing its own `n`: `fns[0](10)=11`, `fns[2](10)=13`.
- Single arrows and `.map` capture closures still work unchanged.

## Boundary

Triple nesting where the innermost arrow captures a binding that is *itself* a
capture of a middle arrow (`(a) => (b) => (c) => a + b + c`) is still rejected
at check time (`'a' not accessible from inner function`) — a pre-existing
capture-depth limitation in the checker, not addressed here. This change is
codegen-only and fixes every nesting the checker already accepts.

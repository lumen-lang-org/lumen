# 373 — Optional class fields default to null; static async methods

Two class-emission fixes found while probing.

## 1. Optional field with no initializer read undefined memory

```ts
class C { name?: string; }
const c = new C();
c.name == null   // was: false (garbage) — should be true
```

An instance is built with `__sa().create(C)`, which returns *undefined* memory;
struct-level field defaults don't apply to `create`. A field with an
initializer is set via the synthesized ctor assignments, and a ctor parameter
sets its field — but an optional field that is neither initialized nor assigned
stayed undefined.

**Fix** (`lumen_emit_class.zig`): after `create` (heap `__init`) and in the
by-value `__initv`, emit `self.<field> = null;` for every optional instance
field with no initializer. `__initv` now also uses `var self` when such a field
exists (so it can be assigned). A ctor that assigns the field overwrites the
null.

## 2. Static async methods didn't resolve their promise

```ts
class F { static async make(n: i32): Promise<i32> { return n * 3; } }
// backend error: expected '*LumenPromise(i32)', found 'i32'
```

Static methods emit through a separate path in `emitClass` (as
`__static_m_<name>` free functions) that — unlike instance methods (spec 372) —
did not set `g_async_inner`, so `return v` emitted a bare value instead of
resolving the promise.

**Fix**: the static-method emit sets `g_async_inner` to the promise inner type
for an async static method and adds the async-`void` trailing
`return __promiseResolved(void, {})`, mirroring instance methods.

## Verified

`zig build` + `zig build test` green. Probes:

- `class C { name?: string }` → unset `c.name == null` is `true`, `c.name ??
  "unnamed"` = `unnamed`.
- Assigning the field later reads the value (`bob`).
- Optional field alongside a ctor-set field: `c.name ?? "unnamed"` = `unnamed`,
  `c.label` = `x`.
- Optional `i32` field → `c.count ?? -1` = `-1`.
- `static async make` → `await F.make(9)` = `27`.

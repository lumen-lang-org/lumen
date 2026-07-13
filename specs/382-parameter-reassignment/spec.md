# 382 — Function parameter reassignment

## Problem

Reassigning a parameter inside its body — a very common pattern
(`x = x + 1`, loop counters, clamping) — failed at the native backend with
"cannot assign to constant", because Zig function parameters are `const`:

```ts
function clamp(x: i32): i32 { if (x > 100) { x = 100; } return x; }
```

The checker already marked parameters mutable (it intended this to work); only
the emit didn't handle it.

## Change

When a body reassigns a non-`Ref` parameter, the incoming value is named
`<name>__mp` in the signature and a mutable local `var <name> = <name>__mp;` is
bound at the top of the body.

- **`lumen_emit_analysis.zig`**: `bodyReassignsBinding` detects `name = …`
  (excluding `Ref` deref writes) and `name++`/`name--` anywhere in a body;
  `paramSigName` returns the renamed signature identifier; and
  `emitReassignedParamCopies` emits the mutable-copy locals.
- Wired into every parameter emit site: free functions, instance methods,
  static methods, constructors (`__init` and the by-value `__initv`), and
  arrows. In arrows the reassigned params skip the `_ = &name` used-marker
  (their copy already reads the incoming value).

`Ref<T>` parameters are untouched (they mutate through the pointer). A parameter
that is never reassigned keeps its name and emits exactly as before.

## Verified

`zig build` + `zig build test` green. Probes:

- `x = x * 2` in a free function → `10`.
- Reassignment in a method, static method, constructor, and arrow.
- Loop-counter parameter (`while (n > 0) { …; n = n - 1; }`).
- `n++` increment parameter.
- A real algorithm — Collatz step count reassigning `n` — → `8` for `6`.
- Regressions: callback params, generic params, and `Ref<T>` params unchanged.

## Boundary

Assignment-based control-flow narrowing is still absent: after
`if (x == null) { x = 0; }` the checker does not narrow `x` to non-null for a
later `return x` (a `T | null` parameter). That is a separate flow-analysis
feature; plain reassignment of an already-correctly-typed value is what this
spec fixes.

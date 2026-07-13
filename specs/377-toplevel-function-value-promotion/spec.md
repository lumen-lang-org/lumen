# 377 — Top-level function-value bindings are module-promoted

## Problem

A top-level `const` bound to an arrow/function value, referenced inside a
function, failed to compile:

```ts
const add = (a: i32, b: i32): i32 => a + b;
function main(): void { console.log(add(2, 3)); }  // use of undeclared identifier '__lumen_0_add'
```

Top-level bindings referenced from within a function are promoted to module
globals (declared `undefined`, assigned in `main`) so the function can see them
(spec 346/347). But `promotableType` excluded `.func_type`, so a function-value
binding stayed a `main` local and was invisible to other functions.

## Change

`lumen_emit.zig`, `promotableType`: removed `.func_type` from the exclusion. A
function-value binding is a fat-pointer struct value like any other — it
promotes the same way (module-scope `var f: LumenFn_... = undefined;`, assigned
at its top-level position in `main`). Only `.void`/`.none` remain non-promotable.

## Verified

`zig build` + `zig build test` green. Probes:

- `const add = (a, b) => a + b; function main() { add(2, 3) }` → `5`.
- A curried top-level arrow used inside a function
  (`const compose = (p) => (m) => p + m; ... compose("! ")("done")`) → `! done`.
- Top-level arrow still callable at top level.
- A top-level arrow passed as a callback argument → works.
- Full integration (optional fields + `this.x` `&&` narrowing + async method +
  curried top-level arrow in one program) compiles and runs.

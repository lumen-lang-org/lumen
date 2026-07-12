# Spec 346 — Module-level scalar state accessible from functions

## Goal

Let a function read and write a top-level scalar binding — the module-level
constant / counter / flag pattern:

```ts
let count = 0;
function inc(): void { count = count + 1; }
inc(); inc();
console.log(count);              // 2

const base = 100;
function withBase(x: i32): i32 { return base + x; }
```

## Motivation

Top-level bindings were emitted as locals inside the generated `main`, so any
function referencing one failed to compile with `use of undeclared identifier`.
Module-level constants and mutable state (counters, config, feature flags) are
ubiquitous, so this was a sharp, common gap — even reading a top-level `const`
from a function broke.

## Behavior

A top-level scalar binding (`i32`/`i64`/`number`/`boolean`/`string`/an enum)
that is referenced by any function, method, or constructor body is promoted to a
module-level global: declared at file scope and assigned at its original
top-level position in `main` (preserving evaluation order and side effects, so a
computed initializer like `const cfg = compute()` still runs where written).
Reads and writes from functions resolve to that global. Bindings not referenced
by any function keep their previous `main`-local emission. Non-scalar top-level
bindings (arrays, records) referenced from functions are not covered by this
slice.

## Implementation

- `src/lumen_emit.zig`: `emitProgram` promotes a top-level `var_decl` whose type
  is a promotable scalar and whose name is referenced by a function/method/ctor
  (`referencedByFunction`) — emitting a `var name: T = undefined;` global and, in
  `main`, a `name = <init>;` assignment at that position.

## Verification

- `zig build` and `zig build test` green.
- A function-read `const`, a function-mutated `let` counter, a string constant,
  an enum-typed mutable global, and a global with a computed (function-call)
  initializer all compile and run correctly; a top-level binding used only at top
  level is unaffected.

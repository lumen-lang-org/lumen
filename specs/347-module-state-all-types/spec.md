# Spec 347 — Module-level state of any type from functions

## Goal

Extend module-level state promotion (spec 346) beyond scalars to arrays,
records, tuples, `Map`/`Set`, and optionals:

```ts
const primes: i32[] = [2, 3, 5, 7];
function nth(i: i32): i32 { return primes[i]; }        // 5

const cache = new Map<string, i32>();
function put(k: string, v: i32): void { cache.set(k, v); }
```

## Motivation

Spec 346 promoted only scalar top-level bindings; an array/record/Map/Set/tuple
referenced from a function still failed to compile. These are just as common for
module-level tables, config objects, and caches.

## Behavior

Any top-level binding whose type is not a function/closure or a value-less type
(`void`/`null`) and which is referenced by a function/method/constructor is
promoted to a module global: declared `undefined` at file scope and initialized
at its original position in `main`. Array/record/Map/Set/tuple initializers
already emit as self-contained expressions, so the in-`main` assignment yields
the correct value. Function-typed top-level bindings (closures with captures)
remain excluded.

## Implementation

- `src/lumen_emit.zig`: `promotableType` now returns true for every type except
  `func_type`, `void`, and `none`.

## Verification

- `zig build` and `zig build test` green.
- A module-level `i32[]`, record, tuple, `Map`, and `Set` are all readable and
  mutable from functions; scalar promotion (spec 346) and top-level-only bindings
  are unchanged.

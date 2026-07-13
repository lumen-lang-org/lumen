# 411 — `structuredClone(x)` for value types

## Problem

`structuredClone` was undefined, so the standard modern-TS deep-copy call failed:

```ts
const p: P = { a: 1, b: 2 };
const q = structuredClone(p); // undefined variable 'structuredClone'
```

## Approach

Lumen records are immutable value types and arrays are immutable, so a deep copy
is observationally identical to the source — assigning a record already copies it
by value. `lumen_check_expr.zig`'s global-call handling now recognizes
`structuredClone(x)`: it lowers the call to the argument expression itself
(returning the argument's type), exactly like `Object.freeze`. A class-instance
argument (a heap reference whose deep copy can't be expressed here) is rejected
with a clear diagnostic.

## Verification

- `structuredClone({a:1,b:2})` → usable copy (`q.a + q.b` → `3`).
- Arrays and scalars clone through (`[1,2,3]`, `42`).
- Nested records clone (`o.inner.v` → `9`).
- A class-instance argument reports "structuredClone of a class instance is not
  supported — clone its fields into a new instance, or use a record type".
- Full `zig build` + test suite green.

## Notes

Class instances (reference types) are intentionally out of scope — deep-cloning
a heap object graph has no value-model lowering. Records and arrays cover the
data-copy use case.

# 424 — generic inference through a `Box<T>` record/class parameter

## Problem

A generic function whose parameter is a user generic type (`Box<T>`,
`Pair<K,V>`) couldn't infer its type parameters from the argument:

```ts
type Box<T> = { v: T };
function unwrap<T>(b: Box<T>): T { return b.v; }
const bx: Box<number> = { v: 5 };
unwrap(bx); // error: cannot infer type here [E_TYPE_INFER]
```

`unifyAnnotation` had no case for a `Base<...>` pattern, and the argument's type
is a *specialized* mangled name (`Box__number`) that erased its type arguments.

## Approach

- **Registry** (`lumen_check.zig` / `lumen_check_generics.zig`): record each
  specialization's concrete type-argument annotations, keyed by its mangled name
  (`spec_type_args`), in `specializeType` and `specializeClass`.
- **`unifyAnnotation`**: for a `Base<...>` pattern against a `named`/`class_type`
  argument, look the argument's mangled name up in `spec_type_args` and unify
  each comma-separated pattern argument against the recovered concrete type
  (top-level-comma split with depth tracking).

## Verification

- `unwrap(bx)` with `Box<number>` → `5`; `Box<string>` → `hi`.
- `Pair<K,V>` parameter: `getKey(p)` infers `K` → `a`.
- Generic *class* parameter (`get(b: Box<T>)` with `new Box<number>(7)`) → `7`.
- Explicit type args, `T[]` array inference, tuple inference unchanged.
- Full `zig build` + test suite green.

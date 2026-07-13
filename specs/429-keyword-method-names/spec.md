# 429 — method names that collide with Zig keywords

## Problem

A class method whose name is a Zig keyword or primitive failed to compile:

```ts
class C { test(): number { return 5; } }   // backend: expected '(', found 'test'
class C { error(): string { ... } }         // backend: expected '(', found 'error'
class C { type(): string { ... } }          // backend: name shadows primitive 'type'
```

The method definition (`fn test(...)`) and the call site (`obj.test(...)`) emitted
the raw name, which Zig rejects for reserved words.

## Approach

Emit both the method definition name and the instance-call name through
`emitFieldName`, which wraps a reserved identifier as `@"name"`
(`isZigReservedField` already lists `test`, `error`, `type`, `fn`, …). Accessor
(`__get_`/`__set_`), static (`__static_m_`), and super-copy (`__super_`) names are
already prefixed and unaffected.

## Verification

- `test`, `error`, `type` as method names all run (`5`, `e`, `t`).
- `this.test()` from within a method works (`10`).
- Interface dispatch on a `test` method works (`true`).
- Ordinary method names unchanged.
- Full `zig build` + test suite green.

## Notes

Found while validating interface polymorphism (spec 428); pre-existing and
orthogonal to that feature.

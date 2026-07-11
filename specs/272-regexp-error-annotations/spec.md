# Spec 272: RegExp and Error type annotations

## Goal

```ts
const re: RegExp = /^[a-z]+[0-9]$/
const err: Error = e        // in a catch block
```

Previously `RegExp` resolved to an unknown named type — producing the
absurd "expected `RegExp`, got `RegExp`" — and `Error` had no annotation
spelling at all.

## Semantics

The annotation resolver maps `RegExp` to the regex type and `Error` to the
error-object type (a caught error's type), the reverse of their display
names. Everything else unchanged.

## Success Criteria

- **SC-001**: Annotated regex binding compiles; `.test()` works.
- **SC-002**: `const err: Error = e` in a catch compiles; `.message` reads.
- **SC-003**: `zig build` and `zig build test` stay green.

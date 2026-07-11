# Spec 280: unused locals warn but still compile

## Goal

```text
main.ts:3:7: warning: unused variable 'entries2'
```

…and the program builds and runs. Previously the warning was followed by a
hard backend failure ("unused local constant … likely a Lumen compiler
bug") because the generated Zig rejects unused locals.

## Semantics

When the checker's scope-exit pass flags a never-referenced binding
(spec 229), it also marks the declaration; emission appends a `_ = &name;`
discard so the generated code compiles. JS semantics: unused variables are
a lint concern, not an error.

## Success Criteria

- **SC-001**: A program with an unused local warns and runs (exit 0).
- **SC-002**: Used variables emit no discard; `zig build` and
  `zig build test` stay green.

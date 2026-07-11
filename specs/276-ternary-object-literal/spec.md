# Spec 276: object literals borrow the other ternary branch's type

## Goal

The immutable-update idiom works:

```ts
this.todos = this.todos.map((t: Todo): Todo =>
  t.id == id ? { id: t.id, title: t.title, done: !t.done } : t)
```

Previously the object-literal branch couldn't self-infer and the whole
ternary failed with "type mismatch".

## Semantics

When exactly one ternary branch is an object literal and the other types to
a named record, the literal is checked assignable against that record type
(the same contextual trick the `cond ? [x] : []` empty-array case already
used) and the ternary types as the record. Everything else unchanged.

## Success Criteria

- **SC-001**: The todo-toggle map above compiles; a full end-to-end app
  probe (classes, throws, JSON, template literals) runs correctly.
- **SC-002**: A literal that doesn't match the record still errors with the
  property-level messages (specs 240).
- **SC-003**: `zig build` and `zig build test` stay green.

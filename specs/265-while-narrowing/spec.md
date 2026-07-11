# Spec 265: while-condition narrowing + non-optional `??` message

## Goal

The pointer-chasing loop idiom type-checks:

```ts
let cur: Node | null = this.head
while (cur != null) {
  total += cur.value      // cur: Node here
  cur = cur.next
}
```

and a `??` whose left side can never be null explains itself:

```text
error: left side of `??` is `i32`, which can never be null — remove the `??`
```

## Semantics

`while (x != null)` narrows `x` (variable or single-level field path)
inside the loop body, same rules as `if`. The `??` operator on a
non-optional left side names the type instead of a bare mismatch.

## Success Criteria

- **SC-001**: A linked-list sum loop compiles and runs correctly.
- **SC-002**: `value ?? fallback` on a non-optional reports the tailored
  message.
- **SC-003**: `zig build` and `zig build test` stay green.

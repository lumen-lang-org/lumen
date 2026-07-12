# Spec 290: indexing and await diagnostics name the type

## Goal

```text
main.ts:2:1: error: cannot index `i32` — indexing needs an array, string, or tuple
main.ts:2:7: error: `await` needs a Promise, got `i32` — only `async`
functions return a Promise
```

Both were previously bare codes (`E_TYPE_MISMATCH`, `E_AWAIT_NOT_PROMISE`).

## Success Criteria

- **SC-001**: Indexing a non-indexable value names its type and what
  indexing accepts.
- **SC-002**: `await` on a non-Promise names the type and points at
  `async`.
- **SC-003**: `zig build` and `zig build test` stay green.

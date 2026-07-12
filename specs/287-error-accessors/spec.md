# Spec 287: Error.name and Error.toString()

## Goal

```ts
try { risky() } catch (e) {
  console.log(e.name)        // Error
  console.log(e.message)     // boom
  console.log(e.toString())  // Error: boom
}
```

Previously only `e.message` existed; `e.name` and `e.toString()` were type
errors.

## Semantics

A caught error (`error_obj`, which is the message string at runtime) gains:
- `.name` — always the constant `"Error"` (Lumen has no custom Error
  subclasses); the receiver is still evaluated for any side effect.
- `.toString()` — `"Error: " + message`.

An unknown Error method reports a did-you-mean over `toString`.

## Success Criteria

- **SC-001**: `e.name`, `e.message`, `e.toString()` print `Error`, the
  message, and `Error: <message>`.
- **SC-002**: `e.stack()` (unsupported) reports the unknown-method message.
- **SC-003**: `zig build` and `zig build test` stay green.

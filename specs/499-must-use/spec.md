# Spec 499: `@must_use`

## Goal

```text
client.ts:14:1: warning: result of 'receive()' is discarded — it is marked
@must_use, so the value it returns is the reason to call it; assign it:
`let x = receive(...)`
```

`receive(ws)` as a statement is the shape of a real bug. `packages/websocket`
returns a new connection rather than mutating the one passed in — records are
immutable — so a call whose result is dropped loses every frame that arrived
in the same packet. Nothing said so: the call type-checks, runs, and silently
does nothing.

Spec 271 already warns for the same mistake on array and string transforms,
but only those: its rule is "the receiver is an array or a string", which no
package type can join. A library author cannot mark their own transform.

## Semantics

`@must_use` on a function declaration marks its return value as the reason to
call it. An expression statement that discards a call to such a function
warns. Assigning, returning, or passing the result is unaffected.

The marker is a built-in: it names no module and runs nothing, unlike an
ordinary decorator (spec 455), which is an imported function the compiler
calls while compiling. `isBuiltinMarker` in `lumen.zig` is what keeps the
decorator driver from demanding an import for it.

A void function carrying the marker is not an error — there is simply nothing
to discard, so nothing warns.

## Success Criteria

- **SC-001**: `receive(c);` on a `@must_use` function warns.
- **SC-002**: `c = receive(c);` does not.
- **SC-003**: a call to an unmarked function discarded as a statement does not
  warn — the marker is opt-in, and discarding a result is ordinary otherwise.
- **SC-004**: `@must_use` compiles with no import of that name, and an
  ordinary decorator still requires one.
- **SC-005**: `zig build` and `zig build test` stay green.

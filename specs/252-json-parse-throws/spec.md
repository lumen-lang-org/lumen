# Spec 252: JSON.parse raises a catchable error on invalid input

## Goal

```ts
try {
  const r: Repo = JSON.parse<Repo>("not json")
} catch (e) {
  console.log(e.message)   // JSON.parse: invalid JSON (SyntaxError)
}
```

Previously invalid input silently returned a zeroed value (empty strings,
zero numbers) — no error, no signal — matching neither JS (SyntaxError) nor
the language's own explicitness goals.

## Semantics

In location-tracked builds (the default) `JSON.parse<T>` raises a Lumen
exception on malformed input, flowing through the spec-245 propagation
machinery: catchable with try/catch, `try`-forwarded through throwing
functions, and rendered as a normal `Uncaught Error` with position and
trace otherwise. Release-fast builds keep the old zeroed fallback (no
exception machinery there).

## Success Criteria

- **SC-001**: Invalid JSON inside try/catch is caught with the message;
  valid parse after the catch still works.
- **SC-002**: Uncaught invalid JSON reports position + `Uncaught Error`.
- **SC-003**: `zig build` and `zig build test` stay green.

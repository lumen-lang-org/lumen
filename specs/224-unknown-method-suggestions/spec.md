# Spec 224: unknown-method diagnostics with suggestions and design hints

## Goal

Make an unknown method call on a string or array explain itself:

```text
error: `string` has no method 'toUperCase' — did you mean 'toUpperCase'?
error: `array` has no method 'fliter' — did you mean 'filter'?
error: `array.push` is not supported: arrays are immutable — use
`a = [...a, x]` or `a.concat([x])`
```

Previously all of these printed `E_TYPE_MISMATCH` with no explanation.

## Semantics

- An unresolved string/array method name reports
  ``erecv` has no method 'name'`` plus a did-you-mean over the receiver's
  full method table (same bounded edit distance as spec 222).
- The classic JS mutators excluded by design — `push`, `pop`, `shift`,
  `unshift`, `splice` — get a targeted message stating the immutability
  design and the idiomatic immutable alternative, instead of a generic
  unknown-method.

## Success Criteria

- **SC-001**: `"hi".toUperCase()` suggests `toUpperCase`;
  `[1,2].fliter(...)` suggests `filter`.
- **SC-002**: `a.push(x)` explains immutability and shows `[...a, x]` /
  `concat`; `pop`/`shift`/`unshift`/`splice` get their own hints.
- **SC-003**: A name far from every method prints without a suggestion; valid
  method calls are unchanged.
- **SC-004**: `zig build` and `zig build test` stay green.

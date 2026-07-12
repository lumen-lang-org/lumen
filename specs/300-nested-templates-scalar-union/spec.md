# Spec 300: nested template literals + scalar-union guidance

## Goal

Template literals nest inside interpolations:

```ts
`${n > 3 ? `big:${n}` : "small"}`     // big:5
`hi ${`${name}!`}`                    // hi amy!
`outer ${`mid ${`inner ${n}`}`}`      // outer mid inner 2
```

And a scalar union gets guidance instead of a bare "syntax error":

```text
error: only `T | null` and discriminated record unions are supported — for
a mix of shapes, declare `type U = A | B` over named record types with a
shared literal tag
```

## Semantics

- The template lexer scans to the matching closing backtick, treating
  `${...}` as an opaque interpolation: nested braces, quoted strings, and
  nested template literals inside an interpolation do not close the outer
  template. Implemented with mutually-recursive `templateBodyEnd` /
  `skipInterp` scanners; line tracking spans the whole body.
- `i32 | string`-style inline unions (neither `T | null` nor a named
  discriminated union) report a tailored message.

## Success Criteria

- **SC-001**: Template literals nested one, two, and three levels deep
  (including inside a ternary) evaluate correctly.
- **SC-002**: Plain templates, object literals / method calls in
  interpolations, and `T | null` are unregressed.
- **SC-003**: A scalar union annotation reports the guidance message.
- **SC-004**: `zig build` and `zig build test` stay green.

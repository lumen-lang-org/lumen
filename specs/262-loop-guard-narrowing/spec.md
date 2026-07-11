# Spec 262: loop guard narrowing (continue/break) + inline-object-type message

## Goal

The parse-and-skip loop idiom type-checks:

```ts
for (const part of raw.split(",")) {
  const n: i32 | null = parseInt(part)
  if (n == null) {
    bad++
    continue
  }
  total += n         // n: i32 here (was: type mismatch)
}
```

Also, an inline object type annotation gets a real message:

```text
error: inline object types are not supported — declare a named type
(`type T = { ... }`) and use its name
```

(was a bare "syntax error").

## Semantics

A guard clause whose then-branch unconditionally leaves the surrounding
flow via `break` or `continue` narrows the rest of the enclosing block,
exactly like `return`/`throw` guards (spec 260) — including union
complements (spec 259).

## Success Criteria

- **SC-001**: The continue-guard loop compiles and computes 11/1.
- **SC-002**: `{ a: i32 } | null` in type position reports the named-type
  guidance.
- **SC-003**: `zig build` and `zig build test` stay green.

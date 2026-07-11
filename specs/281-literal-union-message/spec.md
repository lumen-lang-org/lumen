# Spec 281: string-literal-union mismatches list the valid members

## Goal

```text
main.ts:5:1: error: "bogus" is not a valid `State` — expected
"idle" | "loading" | "done"
```

Previously a bare "type mismatch".

## Success Criteria

- **SC-001**: Assigning an out-of-union string literal reports the value,
  the union name, and the member list.
- **SC-002**: Valid members assign as before; `zig build` and
  `zig build test` stay green.

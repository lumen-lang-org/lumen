# Spec 293: guidance for abstract classes, namespaces, generators

## Goal

Three more TS constructs V1 doesn't have now explain what to use instead,
rather than a cryptic parse error:

```text
error: abstract classes are not supported yet — use an `interface` for the
contract a subclass must implement, or a base class with concrete methods
error: namespaces are not supported — organize code into files and use
`import`/`export`
error: generator functions (`function*`/`yield`) are not supported —
return an array, or build values into one
```

## Semantics

Parser-level guidance only; `abstract`/`namespace`/`module` in statement
position and `function*` each report their message. No behavior change for
supported code.

## Success Criteria

- **SC-001**: Each construct reports its tailored message.
- **SC-002**: `zig build` and `zig build test` stay green.

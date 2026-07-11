# Spec 267: record-shape guidance messages

## Goal

Two more anonymous-shape constructs point at the named-type idiom:

```text
error: union variants must be named types — declare each variant as its own
`type` and write `type U = A | B`
      # type S = { kind: "circle", r: f64 } | { ... }

error: an object literal needs a named record type — declare
`type T = { ... }` and annotate: `const x: T = { ... }`
      # const obj = { x: 1, y: 2 }
```

Previously: "syntax error" and "cannot infer variable type".

## Success Criteria

- **SC-001**: Both probes report the tailored message; the named-type
  versions (including object destructuring) compile and run.
- **SC-002**: `zig build` and `zig build test` stay green.

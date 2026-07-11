# Spec 231: `lumen run` keeps program output clean

## Goal

`lumen run app.ts` prints only the program's own output — no
`compiled app.ts -> app` banner:

```sh
$ lumen run hello.ts
hello world
```

`lumen compile` keeps its banner (its purpose is producing the artifact).

## Implementation

A `build_quiet` action, identical to `build_exe` except the success banner is
suppressed; `lumen run` compiles with it. Diagnostics and warnings still print
on failure.

## Success Criteria

- **SC-001**: `lumen run` output is exactly the program's output.
- **SC-002**: `lumen compile` still prints `compiled x.ts -> x`.
- **SC-003**: `zig build` and `zig build test` stay green.

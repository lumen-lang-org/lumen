# Spec 249: CLI version/help/unknown-command + string throws

## Goal

```text
$ lumen version          # also --version, -v
lumen 0.1.0-dev
$ lumen bogus
error: unknown command 'bogus'
usage: ...
```

Previously `lumen --version` reported "expected a .ts source file, got
--version" and any typo'd subcommand was treated as a file path.

Also accepts JS-style string throws:

```ts
throw "plain string"     // caught as e.message == "plain string"
throw 42                 // error: can only throw an Error or a string,
                         // got `i32` — write `throw new Error(...)`
```

## Semantics

- `lumen version|--version|-v` prints the version; `help|--help|-h` prints
  usage (exit 0). A bare `.ts` path still compiles (shorthand); anything
  else is an unknown command: named error + usage, exit 2.
- `throw <string>` is accepted (an Error carries a string message at
  runtime, so the lowering is identical); throwing any other type names the
  type and suggests `new Error(...)`.

## Success Criteria

- **SC-001**: version/help/unknown-command behave as above.
- **SC-002**: A thrown string is caught with the string as `e.message`;
  `throw 42` reports the tailored error.
- **SC-003**: `zig build` and `zig build test` stay green.

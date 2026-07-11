# Spec 227: `lumen check`

## Goal

Type-check without building:

```sh
$ lumen check app.ts
app.ts: no errors        # ~16 ms

$ lumen check broken.ts
broken.ts:1:7: error: type mismatch: expected `i32`, got `string`
...
```

The full compile pays the native backend (seconds); editors, save-hooks, and
CI lint steps only need the diagnostics. `lumen check` runs parse + type-check
and stops — no code generated, no binary written.

## Semantics

`lumen check <file.ts>`:

- runs the same front end as `lumen compile` (same imports, same diagnostics,
  including multi-error reporting and colors);
- on success prints `<file>: no errors` and exits 0;
- on errors prints the standard diagnostics and exits 1;
- never writes the generated `.zig` or invokes the backend.

## Success Criteria

- **SC-001**: A valid file reports `no errors` in milliseconds and produces no
  binary.
- **SC-002**: A broken file reports the same diagnostics as `lumen compile`
  and exits nonzero.
- **SC-003**: usage text lists the command; `zig build` and `zig build test`
  stay green.

# Spec 229: unused-variable warnings

## Goal

Warn (without failing the build) on `let`/`const` bindings that are never
referenced:

```text
g.ts:1:7: warning: unused variable 'unused'
  1 | const unused = 5
g.ts: no errors
```

## Semantics

- At every scope exit (blocks, function bodies, loops, the top level), any
  `let`/`const` binding never read or written after its declaration warns
  with its declaration position.
- Underscore-prefixed names (`_scratch`) opt out, matching convention.
- Function parameters and catch captures do not warn (V1 scope).
- Warnings render after diagnostics (yellow `warning:` on a TTY) and never
  change the exit code — a warned program still compiles, runs, and `lumen
  check` still reports `no errors`.

## Implementation

Bindings carry a `used` flag set by every scope lookup; `popScope` collects
warnings for unused declarations; the root scope is now popped too so
top-level bindings participate. Warnings flow to the CLI through a
`CompileOptions.warnings` out-list.

## Success Criteria

- **SC-001**: An unused top-level and an unused function-local `const` each
  warn with the right position.
- **SC-002**: `_name` does not warn; fully-used programs produce no warnings
  (verified over a class/loop/closure/try capstone).
- **SC-003**: Exit codes are unchanged by warnings; `zig build` and
  `zig build test` stay green.

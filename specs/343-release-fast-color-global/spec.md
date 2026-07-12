# Spec 343 — Fix `--release-fast` codegen (`__lumen_color` undeclared)

## Goal

Make `lumen compile --release-fast` build again.

## Motivation

Compiling any I/O program with `--release-fast` failed with
`use of undeclared identifier '__lumen_color'`. The runtime location/diagnostic
globals (`__lumen_line`, `__lumen_color`, the call-stack frames, …) are emitted
only when `options.runtime_locations` is set, which release-fast turns off — but
`main` still emitted an assignment `__lumen_color = ...` unconditionally,
referencing a global that no longer existed.

## Behavior

The `__lumen_color` initialization in `main` is now gated by
`options.runtime_locations`, matching the global's declaration. Debug builds
(location tracking on) are unchanged; release-fast builds compile and run.

## Implementation

- `src/lumen_compiler.zig`: wrap the `__lumen_color = ...` assignment in `main`
  in `if (options.runtime_locations)`.

## Verification

- `zig build` and `zig build test` green.
- `lumen compile --release-fast <io program>` builds a native binary and runs
  (verified with the `bench/` programs, which match their Node counterparts
  bit-for-bit).

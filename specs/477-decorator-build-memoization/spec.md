# Spec 477: one build per decorator, and a Debug mode for throwaway binaries

## Goal

`lumen check api.ts` — a file with fifteen `@controller` applications — took
329 seconds. Parse, expansion and typecheck of the same program without
decorators is under a third of a second. The whole wait was `runDecorators`
compiling one helper program fifteen times.

## Why it happened

A decorator is compiled and run: `buildAndRun` writes an entry point beside
the module, builds it, executes it with the application's description as
`argv[1]`, and reads the value it prints. The built program depends only on
the module and the exported name — the application reaches it at *run* time —
yet the build was inside the per-application loop, so fifteen sites built a
byte-identical binary fifteen times at ~21 seconds each.

Nothing downstream could save it either. The entry file's name embeds the
process id (deliberately, so two concurrent compiles keep out of each other's
files), and that name lands inside the generated source, so no two runs ever
present the same bytes to `zig build-exe` — and `zig build-exe` in Zig 0.16
writes no whole-compilation cache in any case (verified: back-to-back
identical builds, zero new manifests).

## What changed

- The Expander memoizes decorator binaries on `(module path, exported name)`
  for the life of one expansion. The build happens once; every further
  application of the same decorator only runs the binary with its own
  description. Cleanup moves from per-build to the expansion root, since the
  binaries are now shared; on the error path they are left behind — a stray
  temp file beats deleting evidence mid-diagnosis.

- `CompileMode` gains `debug`, used only for these throwaway builds: the
  self-hosted backend and linker instead of LLVM, measured ~35x faster on a
  decorator module (0.6s against 21s). A binary that lives for one expansion
  and is then deleted gets nothing from optimized codegen; the wait to build
  it is its entire cost. Binaries a user keeps are untouched — `compile`
  still defaults to ReleaseSafe.

## Measured

| | before | after |
|---|---|---|
| `lumen check api.ts` (15 `@controller`) | 329.6s | 1.28s |
| `lumen compile api.ts` | ~325s | 4.6s |

## Semantics

None changed. The decorator still runs once per application with its own
description; only the redundant builds are gone. The existing spec 455
conformance cases are the regression net — a memoization with an
application-dependent build would fail `two-decorators-in-source-order`
immediately.

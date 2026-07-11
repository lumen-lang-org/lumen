# Spec 220: backend failures map back to the .ts source

## Goal

When the native backend rejects the generated Zig, report a located `.ts`
diagnostic instead of a black box:

```text
g.ts:3:1: error: division by zero here causes illegal behavior
  3 | console.log(a / b)
    | ^
note: the native backend rejected this statement's generated code — likely a
Lumen compiler bug; please report it
```

Previously every backend failure printed only
`error: failed to build native binary for <file>` with zero detail — the worst
diagnostic in the compiler, hit by codegen bugs and by a few genuinely
user-facing cases (comptime division by zero, self-referential record types).

## Semantics

In build mode the backend's stderr is captured (test mode still streams
through). On a nonzero exit:

- the first `gen.zig:LINE:COL: error: MSG` entry is parsed;
- `LINE` is mapped to the `.ts` statement via the `__lumen_line = N;
  __lumen_col = M;` position markers the codegen writes before every
  statement (last marker at or before the failing generated line);
- the error renders through the standard diagnostic printer (file:line:col,
  source excerpt, caret) with the backend's message, plus a note that this is
  likely a compiler bug to report;
- with no mappable marker (a failing type declaration, prelude code) the raw
  message prints without a location;
- with no parsable error line at all, the old summary plus the first few raw
  backend lines print, so the failure is always diagnosable.

## Why additive, not breaking

Diagnostics only. Successful builds and test mode are unchanged.

## Success Criteria

- **SC-001**: `const b = 0; console.log(a / b)` (comptime div-by-zero) reports
  `file:3:1` with the Zig message and caret.
- **SC-002**: A failure with no position marker (self-referential type) still
  shows the backend message.
- **SC-003**: Successful compiles print `compiled x.ts -> x` as before;
  `zig build` and `zig build test` stay green.

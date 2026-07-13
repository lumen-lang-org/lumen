# 388 — Switch over a string enum

## Problem

Switching on a string-enum value failed at the native backend:

```ts
enum S { On = "on", Off = "off" }
function f(s: S): i32 {
  switch (s) { case S.On: return 1; case S.Off: return 0; }  // Zig: cannot compare strings with ==
}
```

A string enum lowers to its `[]const u8` value, but the switch case match
emitted `==` (pointer/scalar equality), which Zig rejects for slices.

## Change

`lumen_emit_stmt.zig`, `emitSwitchCaseMatch`: treat a string enum as
string-like, so case matches use `std.mem.eql(u8, …)` (byte comparison) like a
plain string switch. Numeric enums and non-enum switches are unchanged.

## Verified

`zig build` + `zig build test` green. Probes:

- `switch (s)` over `enum S { On = "on", Off = "off" }` → `f(S.On)=1`,
  `f(S.Off)=0`.
- Numeric-enum switch (`enum D { N, E, S, W }`) still works.
- Plain string switch (`switch (s) { case "a": … }`) unchanged.

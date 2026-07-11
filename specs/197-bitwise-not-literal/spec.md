# Spec 197: bitwise NOT on an integer literal

## Goal

Fix `~<literal>` failing to build:

```ts
~5;   // -6
~0;   // -1
~5 & 0xFF;  // 250
```

Previously `~5` failed to build the native binary, while `~x` on an `i32`
variable worked.

## Root cause

`~` lowered to `~(<operand>)`. A bare integer literal is a Zig `comptime_int`,
and `~` on a `comptime_int` has no fixed width to complement, so Zig rejects it.
An `i32` variable operand already had a width, so it worked.

## Fix

`~` now pins its operand to `i32` (`~(@as(i32, <operand>))`), matching JS's
32-bit bitwise semantics. This is a no-op for an already-`i32` operand and fixes
the literal case.

## Why additive, not breaking

Turns a build failure into correct output; `~x` on an `i32` value is unchanged.
A float operand is still a type error (bitwise operates on integers).

## Requirements

- **FR-001**: `~<int literal>` compiles and yields the bitwise complement.
- **FR-002**: `~<i32 value>` is unchanged; combining `~` with `&`/`|`/`^` works.

## Success Criteria

- **SC-001**: `~5` -> `-6`; `~0` -> `-1`.
- **SC-002**: `~5 & 0xFF` -> `250`; `[5&3, 5|2, 5^1, ~5]` -> `[1,7,4,-6]`.
- **SC-003**: `~x` for `const x: i32 = 5` -> `-6`.
- **SC-004**: `zig build` and `zig build test` stay green.

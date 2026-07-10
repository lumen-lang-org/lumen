# Spec 114: for-of over an array literal

## Goal

`for (const x of [1, 2, 3])` — iterating an array literal directly — failed the
native build ("tuple field index must be comptime-known"), because the literal
lowered to an anonymous tuple that cannot be indexed with a runtime counter.
This makes the common inline-list iteration work.

## Why this is a codegen fix, not an API change

The loop binds the iterable to a `seq` local, then indexes `seq[i]`. For a
literal iterable the anonymous tuple has no runtime indexing. Codegen now
annotates the array `seq` with its slice type (`const seq: []const T = ...;`),
which coerces the literal tuple to a real `[]const T` slice; runtime indexing
then works. Strings keep their existing `[]const u8` sequence.

## Scope

- Applies to `for-of` over array literals of any supported element type.
- Composes with spec 113 (an unused loop variable is still fine).

## Requirements

- **FR-001**: `for (const x of [<elems>])` compiles and iterates the literal's
  elements in order.
- **FR-002**: `for-of` over a typed array binding or a string is unchanged.

## Success Criteria

- **SC-001**: `for (const x of [10, 20, 30]) sum += x` yields `60`;
  `for (const s of ["x", "y", "z"]) joined += s` yields `"xyz"`; iterating a
  typed `int[]` still works.
- **SC-002**: `zig build` and `zig build test` stay green.

# Spec 342 — Clearer immutability diagnostics for indexed and array writes

## Goal

Report a precise, actionable message for an indexed assignment
(`a[0] = 9`, `obj["k"] = v`) and an array-element write, instead of the
record-oriented "record fields are immutable; build a new object instead".

## Motivation

Arrays and records are immutable in V1. An indexed write was flagged by a
lexical pre-scan that had no type information, so it reused the record-field
message even for array indexing — confusing when the target is an array.

## Behavior

- An indexed assignment (`x[i] = ...`) reports: not supported — arrays and
  records are immutable; build a new value instead, with a spread-slice example.
- An array-element write that reaches the checker reports an array-specific
  message pointing at `map`/spread-slice.
- A record field write keeps the record message; class field mutation (through a
  method or setter) is still allowed.

## Implementation

- `src/lumen_compiler.zig`: the lexical indexed-write guard emits an
  index-specific message rather than the `E_DYNAMIC_PROPERTY_WRITE` record code.
- `src/lumen_check_stmt.zig`: a member-write whose receiver is an array reports an
  array-specific immutability message.

## Verification

- `zig build` and `zig build test` green.
- `a[0] = 9` and `obj["k"] = v` produce the indexed-assignment message; a record
  field write keeps the record message; class field mutation via a method still
  compiles.

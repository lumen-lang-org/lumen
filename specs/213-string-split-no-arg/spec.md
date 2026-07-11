# Spec 213: zero-argument `string.split()`

## Goal

Accept `split()` with no separator on a string, which JS returns as a
single-element array of the whole string:

```ts
"hello".split();   // ["hello"]
```

Previously the string form required at least one argument (`E_ARG_COUNT`).

## Why additive, not breaking

Only makes previously-rejected programs compile. The string-separator,
empty-string, limit, and regex-separator forms are unchanged.

## Semantics

`s.split()` with no separator returns `[s]` — a one-element `string[]` holding
the whole string (matching JS, where an omitted separator does not split).

## Requirements

- **FR-001**: `s.split()` returns a one-element array containing `s`.
- **FR-002**: All argument forms (string / empty-string / limit / regex) are
  unchanged.

## Success Criteria

- **SC-001**: `"hello".split()` -> `["hello"]` (length 1, `[0]` is `"hello"`).
- **SC-002**: `"a,b,c".split(",")`, `"abc".split("")`, and `"a1b2".split(/[0-9]/)`
  still work.
- **SC-003**: `zig build` and `zig build test` stay green.

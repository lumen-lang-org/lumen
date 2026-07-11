# Spec 176: `string.split` with a regex separator

## Goal

Allow a regex as the separator of `String.prototype.split`, the common
tokenizing idiom:

```ts
"a12b345c".split(/[0-9]+/);   // ["a", "b", "c"]
"the  quick   brown".split(/\s+/);  // ["the", "quick", "brown"]
```

Previously only a string separator was accepted; a regex reported
`E_TYPE_MISMATCH`. Builds on the match-span infrastructure added in spec 175.

## Why additive, not breaking

Only makes previously-rejected programs compile. `s.split(",")` and
`s.split(",", n)` (string separator, optional limit) are unchanged.

## Semantics

`s.split(re)` splits `s` at every non-overlapping regex match and returns the
pieces (a `string[]`), including a trailing empty piece when the string ends
with a match — matching JS. The `i` flag is honored. A zero-width match cannot
delimit a piece, so an empty pattern yields the whole string as one piece
(the `limit` second argument is not supported for the regex form in V1).

## Implementation

- Runtime (`regex_rt.zig`): `splitRegex` walks `__reFind` spans, collecting the
  gaps between matches.
- Checker: a `split` call with exactly one argument that types as `regexp` sets
  `regex_arg`, flags `program.uses_regex`, and returns `string[]`.
- Emit: `emitStringMethod` routes a `regex_arg` split to `splitRegex(source,
  flags, receiver)`.

## Requirements

- **FR-001**: `s.split(/re/)` splits on each match, returning `string[]`.
- **FR-002**: The `i` flag is honored; the string-separator form is unchanged.
- **FR-003**: A regex bound to a variable works as the separator.

## Success Criteria

- **SC-001**: `"a1b2c3".split(/[0-9]/).join("|")` -> `a|b|c|`;
  `"a12b345c".split(/[0-9]+/).join("|")` -> `a|b|c`.
- **SC-002**: `"the  quick   brown".split(/\s+/).join(",")` -> `the,quick,brown`.
- **SC-003**: `"a,b,c".split(",").join("|")` (string separator) -> `a|b|c`.
- **SC-004**: `zig build`, `zig build test`, and the `regex_rt.zig` unit test
  stay green.

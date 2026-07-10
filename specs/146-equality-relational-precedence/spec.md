# Spec 146: equality binds looser than relational

## Goal

Match JavaScript operator precedence so an equality operator can follow a
relational comparison without parentheses:

```ts
5 > 3 === true     // true   (was: syntax error)
2 < 1 === false    // true
10 > 5 != false    // true
```

Previously the comparison tier accepted only a single operator, so
`5 > 3 === true` left `=== true` unparsed and reported a syntax error; it
required explicit parentheses `(5 > 3) === true`.

## Why additive, not breaking

Only makes previously-rejected programs parse. Every expression that parsed
before still parses the same way — a lone relational or equality comparison is
unchanged. Parenthesized forms are unaffected.

## Semantics

Two precedence tiers, matching JS:

- **Relational** (`< > <= >=`) binds tighter and is parsed first (a single
  comparison, as before).
- **Equality** (`== !=`, and their strict spellings) binds looser and chains
  left-associatively, so `a > b == c` is `(a > b) == c` and `a == b == c` is
  `(a == b) == c`.

## Requirements

- **FR-001**: An equality operator may follow a relational comparison without
  parentheses.
- **FR-002**: Equality chains left-associatively.
- **FR-003**: A single relational or equality comparison behaves exactly as
  before.

## Success Criteria

- **SC-001**: `5 > 3 === true` -> `true`; `2 < 1 === false` -> `true`;
  `10 > 5 != false` -> `true`; `"a" < "b" === true` -> `true`.
- **SC-002**: `1 + 1 === 2` -> `true`; `5 > 3` -> `true`; `3 == 3` -> `true`.
- **SC-003**: `zig build` and `zig build test` stay green.

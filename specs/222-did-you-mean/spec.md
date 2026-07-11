# Spec 222: "did you mean" suggestions for undefined names

## Goal

Suggest the closest known name when a variable or function reference doesn't
resolve:

```text
g.ts:2:1: error: undefined variable 'countr' — did you mean 'counter'?
g.ts:1:1: error: undefined variable 'consle' — did you mean 'console'?
g.ts:2:1: error: undefined variable 'computeTotol' — did you mean 'computeTotal'?
```

Previously the message named only the unknown identifier; a bare
`unknown function` for call typos didn't even include the name.

## Semantics

An unresolved variable read, assignment target, or function call searches for
the closest candidate among:

- every binding in every active scope,
- every declared function,
- common globals (`console`, `Math`, `JSON`, `parseInt`, ...).

Matching uses bounded edit distance (insert/delete/substitute): at most 1 edit
for names of ≤4 characters, 2 edits otherwise; ties keep the first-found
candidate. With no candidate inside the bound, the plain message prints.
Unknown *calls* now also report the name (`undefined variable 'parseIt' — did
you mean 'parseInt'?` instead of `unknown function`).

## Cost

Only runs on the error path; the distance loop gives up early past the bound.

## Success Criteria

- **SC-001**: A one-letter typo of a local, a global, and a user function each
  get the right suggestion.
- **SC-002**: A name far from everything prints without a suggestion.
- **SC-003**: Valid programs are unaffected; `zig build` and `zig build test`
  stay green.

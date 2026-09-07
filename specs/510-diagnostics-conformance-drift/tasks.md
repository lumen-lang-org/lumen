# Tasks: 510 diagnostics-conformance drift

**Input**: spec.md's Group A / Group B findings. All of T001-T013 are now
done (this pass); T014/T015 (the re-verification sweeps) are the
remaining process step.

## Group A — one checker fix, six call sites, eight cases

- [x] T001 Add the missing `[E_TYPE_MISMATCH]` suffix to
  `Checker.failCondition`'s formatted message
  (`src/lumen_check.zig:1412-1422`), matching the bracket convention every
  sibling formatted diagnostic in the file already follows (compare
  `throw_stmt`'s `" [E_THROW_TYPE]"` in `src/lumen_check_stmt.zig:1442`) and
  the guarantee spec 218 makes ("the `E_*` codes remain visible in brackets
  so existing tooling that greps for them keeps working"). Fixes, in one
  place, all six condition-type cases: `native.invalid.if-condition-type`,
  `native.invalid.else-if-condition-type`, `native.invalid.while-condition-
  type`, `native.invalid.for-condition-type`, `native.invalid.do-while-
  condition-type`, `native.invalid.ternary-condition-type`. No fixture or
  manifest edit needed — re-verify with `zig build conformance` against
  `specs/001-typescript-to-zig-native/conformance/manifest.json` after the
  fix.
- [x] T002 Add the same `[E_TYPE_MISMATCH]` suffix to
  `Checker.failUnknownMethod`'s formatted message
  (`src/lumen_check.zig:433-449`) — both the did-you-mean and plain
  branches. Fixes `string.invalid.unknown-method`
  (`specs/014-string-methods/conformance/manifest.json`) and
  `array.invalid.unknown-method`
  (`specs/013-array-methods/conformance/manifest.json`). Do not touch the
  third `failUnknownMethod` call site's fixture
  (`container.invalid.unknown-method`, `specs/020-map-set-tuples`) as part
  of this task — that one is stale for an unrelated reason (T011).

## Group B — fixture/manifest updates, one behavior-change commit each

- [x] T003 `native.invalid.arithmetic-type`: replaced with `let value = [1]
  + 2;` (array + number — verified still `E_TYPE_MISMATCH`, per spec 142
  FR-002/SC-003's own "string + array" carve-out). No manifest change
  needed (`expect.diagnostic` was already the bare code).
- [x] T004 `native.invalid.string-concat-type`: replaced with a record +
  string case (`type Rec = { a: int }; let r: Rec = { a: 1 }; let bad = r +
  "x";`) — deliberately a different non-coercible operand than T003's
  array, per FR-002's "string + object" wording, so the two fixtures stay
  meaningfully distinct rather than duplicating each other. Verified still
  `E_TYPE_MISMATCH`.
- [x] T005 `native.invalid.compound-assignment-type`: replaced with an
  array `+=` (`let acc: int[] = [1]; acc += 2;` — verified still
  `E_TYPE_MISMATCH`; confirmed separately that `name += true` on a string
  DOES now compile, per spec 142's bool-stringify rule, so it would not
  have worked as the replacement).
- [x] T006 `native.invalid.throw-type`: replaced with `throw 42;` —
  verified still reports `E_THROW_TYPE`. `expect.diagnostic` was already
  the bare code, no manifest change needed.
- [x] T007 `error.invalid.throw-string`: replaced with `throw true;` (not
  `throw 42`, to stay distinct from the pre-existing sibling case
  `error.invalid.throw-number`, found while implementing this task — it
  already pins the exact `throw 42` shape T007's own suggested fix would
  have duplicated). **Renamed** `throw-string.ts` →
  `throw-non-error-caught.ts` (the old name was actively wrong once the
  fixture no longer throws a string) and the manifest id to
  `error.invalid.throw-non-error-caught` to match. Reconciled spec 019's
  SC-002, which explicitly listed "throwing a string ... fail[s] before
  native build" as a requirement — noted spec 249 as the amendment rather
  than silently dropping the claim.
- [x] T008 `native.invalid.math-unsupported`: retired as a *Math* case —
  read `mathCallType` in full and confirmed it now covers essentially the
  complete ECMAScript `Math` API (every standard method and constant), so
  no genuinely-still-unsupported member remains to pin, exactly the
  contingency this task's own wording anticipated ("or retire if no such
  member remains worth pinning"). Rather than dropping `E_UNSUPPORTED_STD`
  coverage entirely — it turned out to be the ONLY case anywhere in the
  whole conformance suite exercising that diagnostic — swapped in
  `Promise.race(...)`, a genuinely still-unsupported member of a
  *different* namespace (verified: only `Promise.resolve`/`.all` are
  implemented, per the diagnostic's own wording). **Renamed**
  `math-unsupported.ts` → `promise-unsupported.ts` and the manifest id to
  `native.invalid.promise-unsupported` to match the new content.
- [x] T009 (no separate work — see T006/T010, kept only for numbering).
- [x] T013a `native.invalid.dynamic-property-write` — found missing from
  this task list entirely (spec.md's own Group B table has it; this
  numbered breakdown skipped assigning it a task, an oversight in the
  original investigation, caught only by actually re-running the full
  sweep and seeing it fail). Replaced the index-notation write
  (`user["name"] = "Ada"`, moved off `E_DYNAMIC_PROPERTY_WRITE` onto a
  dedicated code-less message by spec 342) with a dot-notation field write
  on a properly-typed record (`type User = {...}; let user: User = {...};
  user.name = "Ada";` — the original fixture's untyped object literal
  doesn't type-check for a plain field write the way it did for the index
  form, so the replacement needed a named type too) — verified still
  reports the bare, bracketed `E_DYNAMIC_PROPERTY_WRITE`.
- [x] T010 `native.invalid.function-return-type`: `expect.diagnostic`
  updated from `E_RETURN_TYPE` to `E_TYPE_MISMATCH` (fixture unchanged —
  it still correctly demonstrates the rule, spec 218 just moved which code
  fires). `specs/001-typescript-to-zig-native/spec.md`'s `E_RETURN_TYPE`
  doc entry corrected: now describes the missing-`return`-value case it
  actually covers today, with a note on the amendment.
- [x] T011 `container.invalid.unknown-method`: replaced `m.clear()` with
  `m.entries()` — verified `mapMethod` covers
  clear/set/get/has/delete/keys/values/forEach but not `entries`, so this
  still reports `E_TYPE_MISMATCH` (via the function's own generic
  fallback, not `failUnknownMethod` — this case was never affected by the
  Group A bug, confirmed).
- [x] T012 `array.invalid.reduce-arg-count`: replaced the single-seedless-
  arg call with a zero-argument one (`xs.reduce()`) — verified still
  `E_ARG_COUNT`.
- [x] T013 `decorators.invalid.argument-is-not-an-expression`: added
  `examples/invalid/tools/entity.ts` (a minimal, correctly-shaped
  `export function entity(d: Description): string`, mirroring the sibling
  `tools/wrong-signature.ts`'s `Description` shape) and rewrote the fixture
  to import it and use `@entity(1 + 2)` instead of the bare identifier
  `@entity(name)` the fixture previously used (bare identifiers are
  deliberately accepted decorator-arg syntax, per spec.md's own finding).
  Verified: reports exactly `E_DECORATOR_ARG` now, not the unrelated
  "not imported" error the original fixture masked it with.

## Process

- [x] T014/T015 Full targeted re-verification: `specs/001-typescript-to-
  zig-native`, `013-array-methods`, `014-string-methods`,
  `019-error-handling`, `020-map-set-tuples`, `455-decorators` all pass
  after T001-T013 (see the commit this task list was closed in for the
  exact sweep result). A full, all-manifest `zig build conformance` sweep
  (not just the six touched) is the final gate before considering this
  spec done — run it, and if anything surfaces, fix it before closing.
  The `E_*`-doc grep T015 also asks for (checking every remaining
  `specs/*/spec.md` for other code references that might have drifted the
  same way Group B did) has NOT been done yet — a real, separate follow-up,
  not done as part of this pass.

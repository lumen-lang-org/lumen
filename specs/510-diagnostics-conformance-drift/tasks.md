# Tasks: 510 diagnostics-conformance drift

**Input**: spec.md's Group A / Group B findings. Investigation only — none
of these are done yet; a future pass implements them.

## Group A — one checker fix, six call sites, eight cases

- [ ] T001 Add the missing `[E_TYPE_MISMATCH]` suffix to
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
- [ ] T002 Add the same `[E_TYPE_MISMATCH]` suffix to
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

- [ ] T003 `native.invalid.arithmetic-type`
  (`specs/001-typescript-to-zig-native/examples/invalid/arithmetic-type.ts`,
  manifest entry in the same spec's `conformance/manifest.json`): `1 +
  "x"` is valid string concatenation since spec 142. Replace the fixture
  with a genuinely-still-rejected arithmetic mismatch (e.g. an array or
  record operand: `let value = [1] + 2;`, per spec 142 FR-002/SC-003 — still
  `E_TYPE_MISMATCH`) or retire the case if spec 001 no longer needs a
  dedicated arithmetic-type-mismatch example once 142's own conformance
  case covers it.
- [ ] T004 `native.invalid.string-concat-type`
  (`.../examples/invalid/string-concat-type.ts`): same spec 142 change;
  `"count: " + 1` is spec 142's own worked "now valid" example. Same fix
  shape as T003 — needs a non-coercible operand (array/record) to still
  demonstrate a rejection, or retirement.
- [ ] T005 `native.invalid.compound-assignment-type`
  (`.../examples/invalid/compound-assignment-type.ts`): `name += 1` on a
  string now stringifies the RHS (spec 142's `+=` counterpart,
  `src/lumen_check_stmt.zig:864-873`). Replace with a compound-assignment
  case that's still rejected (e.g. `name += true` is fine per spec 142's
  bool rule too — use a non-coercible RHS, or a numeric-slot `&=`/`|=` with
  a non-integer RHS) or retire.
- [ ] T006 `native.invalid.throw-type`
  (`.../examples/invalid/throw-type.ts`): `throw "boom"` is deliberately
  accepted since spec 249. Replace with a thrown value that's still
  rejected (spec 249's own example: `throw 42` → "can only throw an Error
  or a string, got `i32`... `[E_THROW_TYPE]`" — still fires, verified) and
  update `expect.diagnostic` if the message text changed.
- [ ] T007 `error.invalid.throw-string`
  (`specs/019-error-handling/examples/invalid/throw-string.ts` +
  manifest): same spec 249 change. Update the fixture (same fix as T006:
  swap the thrown string for a thrown number, or another non-Error/non-
  string value) **and** reconcile spec 019's own FR-001/SC-002 text, which
  currently still documents "a bare string is rejected" as a requirement —
  either narrow that requirement to non-string/non-Error values or note
  spec 249 as the amendment.
- [ ] T008 `native.invalid.math-unsupported`
  (`.../examples/invalid/math-unsupported.ts`): `Math.random()` is
  implemented. Swap in a `Math.*` member that's genuinely still
  unsupported (check `src/lumen_check_stdlib.zig` for what's NOT handled —
  do not guess) so the case still exercises `E_UNSUPPORTED_STD`, or retire
  if no such member remains worth pinning.
- [ ] T009 `native.invalid.throw-type`/`function-return-type`: not a
  separate task — see T006 above and T010 below respectively (listed here
  only to keep numbering contiguous with spec.md's table order).
- [ ] T010 `native.invalid.function-return-type`
  (`.../examples/invalid/function-return-type.ts` + manifest +
  `specs/001-typescript-to-zig-native/spec.md:305`): update
  `expect.diagnostic` from `E_RETURN_TYPE` to `E_TYPE_MISMATCH` (the fixture
  itself still correctly demonstrates the underlying rule — a returned
  value incompatible with the declared return type — spec 218 just moved
  which code fires). Also update spec 001's doc line 305 so its own
  `E_RETURN_TYPE` description ("Produced when a function returns a value
  incompatible with its declared return type") no longer contradicts actual
  behavior; note there that `E_RETURN_TYPE` is now reserved for a missing
  `return` value (`src/lumen_check_stmt.zig:1415`).
- [ ] T011 `container.invalid.unknown-method`
  (`specs/020-map-set-tuples/examples/invalid/unknown-method.ts` +
  manifest): `Map.clear()`/`Set.clear()` are implemented (spec 088).
  Replace `m.clear()` with a call to a method still absent from
  `src/lumen_check_methods.zig`'s Map/Set surface, or retire.
- [ ] T012 `array.invalid.reduce-arg-count`
  (`specs/013-array-methods/examples/invalid/reduce-arg-count.ts` +
  manifest): single-arg `reduce` (no seed) is valid since spec 132.
  Replace with an arg-count case `reduce`/`reduceRight` still rejects — 0
  arguments, or 3+ (`src/lumen_check_methods.zig:161-165` only accepts 1 or
  2) — to keep exercising `E_ARG_COUNT`.
- [ ] T013 `decorators.invalid.argument-is-not-an-expression`
  (`specs/455-decorators/examples/invalid/decorator-argument-is-not-an-
  expression.ts` + manifest): rewrite the fixture with (a) a real import
  for `entity` (add an `examples/invalid/tools/entity.ts` alongside the
  existing `decorator-not-imported.ts`'s sibling tools, shaped per spec
  455's `export function entity(d: Description): T` contract) so the
  unrelated `E_DECORATOR` "not imported" check no longer fires first, and
  (b) a genuinely non-literal argument — a bare identifier is intentionally
  accepted (`.ident` decorator args, `src/lumen_ast.zig:33-38`) so it no
  longer demonstrates the rule; use an arithmetic expression (`@entity(1 +
  2)`, verified to still report `E_DECORATOR_ARG`) or a call instead.

## Process

- [ ] T014 Once T001/T002 land, re-run the full `zig build conformance`
  sweep (all manifests, not just the ones touched) to confirm no new
  failures were introduced and that the 8 Group-A cases now pass unedited.
- [ ] T015 Once T003-T008 and T010-T013 land, re-run the full sweep again
  to confirm all 19 are green, and grep every remaining `specs/*/spec.md`
  for other `E_*` code references that might have drifted the same way
  Group B did, since this investigation only chased the 19 the harness
  already flagged.

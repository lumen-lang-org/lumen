# Spec 510: diagnostics-conformance drift

**Status**: Draft (investigation only, no fix in this pass) | **Parent**: none
(cross-cuts specs 001, 013, 014, 019, 020, 455)

## Problem

A full `zig build conformance` sweep across every spec manifest turned up 19
pre-existing failures, all in `phase: "diagnostics"` cases (a case that
compiles a fixture `.ts` file expected to be *rejected* with a specific
`expect.diagnostic` substring) — none in the node-target or runtime-behavior
cases. All 19 were confirmed pre-existing: one (`native.invalid.arithmetic-
type`) was independently reproduced against a `git stash`-restored earlier
commit with the identical result, before this investigation started, and
nothing in this investigation touched the checker, the emitter, or any
fixture/manifest.

The 19 span 6 spec manifests: `specs/001-typescript-to-zig-native` (13
cases), `specs/013-array-methods` (2), `specs/014-string-methods` (1),
`specs/019-error-handling` (1), `specs/020-map-set-tuples` (1), and
`specs/455-decorators` (1).

### Method

For each case: read the manifest entry (`id`, `source`, `expect.diagnostic`),
read the `.ts` fixture, then actually run `zig-out/bin/lumen check` and
`zig-out/bin/lumen compile` against the fixture (in a scratch dir) to see
current real behavior — not just re-read the conformance harness's FAIL
line. Diagnostic-message call sites were then read directly in `src/` and
traced with `git log -p -S<snippet>` to the commit (and, where one exists,
the spec) that produced the current behavior, to tell an intentional,
documented change from an accidental one.

The conformance harness (`tools/lumen_conformance.zig`, `checkDiagnostics`)
matches `expect.diagnostic` as a **substring** of the compiler's stderr — it
does not parse a structured code field. That single fact explains most of
this list once you see it: a diagnostic that still fires for exactly the
right reason, worded slightly differently, fails the same way as a
diagnostic that no longer fires at all.

## Findings

**8 of 19 are a genuine, single-root-cause regression** (Group A below): the
checker's semantic check still fires correctly in every one of these 8
cases, but the message-building code silently dropped the bracketed `[E_*]`
code that every sibling diagnostic in the codebase carries — and that spec
218 ("readable diagnostics with type detail") itself explicitly promises
("every remaining raw `E_*` code renders as a sentence with the code kept
in brackets for grep-ability" / "the `E_*` codes remain visible in brackets
so existing tooling that greps for them keeps working"). This is worth
fixing once, in the checker, not 8 times in manifests.

**11 of 19 are stale fixtures/manifests** (Group B below): the program the
fixture contains used to be invalid and legitimately is not anymore — each
one traces to a specific, dated, documented feature commit (several of them
their own numbered specs) that shipped *after* the fixture was written and
never circled back to update it. None of these are checker bugs; the
checker is doing exactly what its own spec says it should.

No case in this list is a "diagnostic reports a totally unrelated error" or
"accepts something it should reject with no error at all downstream" —
every rejection that still happens is happening for the right reason, and
every acceptance that now happens is an intentional widening documented at
the time it shipped. The concerning part is not any individual case; it's
that 6 spec manifests' worth of `.ts` fixtures and 2 spec.md docs (001's own
`E_RETURN_TYPE` and `E_DYNAMIC_PROPERTY_WRITE` entries) have drifted this far
out of sync with real behavior, which only a full, gated conformance sweep
across *every* manifest — not just the manifest most recently touched —
would have caught.

---

## Group A — genuine regressions (checker fix needed)

All 8 share one root cause. `Checker.fail(line, col, msg)`
(`src/lumen_check.zig:345`) just records `msg` verbatim; the CLI's
`humanizeDiag` (`src/lumen.zig:39`) only adds a `[E_CODE]` suffix when `msg`
is an *exact match* for a bare code like `"E_TYPE_MISMATCH"`. Every
diagnostic that instead builds its own descriptive string with
`std.fmt.allocPrint` has to append `" [E_CODE]"` inside that format string
itself to keep the code visible — and every one that predates or postdates
18:07 on 2026-07-11 (`27362c1`/`00d4dec`, the same day's "readable
diagnostics" / "unknown-method suggestions" work, spec 218) does this
(`E_THROW_TYPE`, `E_DECORATOR_ARG`, `failTypeMismatch`'s own fallbacks, …)
— except two helpers written that same day:

- **`Checker.failCondition`** (`src/lumen_check.zig:1412`), added in
  `27362c1` ("feat: truthiness and const-assignment diagnostics explain the
  fix", 2026-07-11 18:07 UTC). Before this commit, a non-boolean condition
  was reported as the bare `self.fail(line, col, "E_TYPE_MISMATCH")` (see
  `d51531f`, "Require boolean while conditions") — which *did* match the
  manifests. `27362c1` replaced that with a friendlier
  `"{construct} condition must be \`boolean\`, got \`{type}\` — truthiness
  is not supported; write {hint}"` and never appended
  `" [E_TYPE_MISMATCH]"`.
- **`Checker.failUnknownMethod`** (`src/lumen_check.zig:433`), added in
  `00d4dec` ("feat: unknown-method suggestions and immutability hints for
  JS mutators", 2026-07-11 17:18 UTC), same story: replaced bare
  `self.fail(line, col, "E_TYPE_MISMATCH")` call sites in
  `arrayMethod`/`stringMethod` with `` "`{recv}` has no method '{name}'"
  `` (plus an optional did-you-mean suffix), no bracket.

Six call sites route through `failCondition` (`if`/`else if` share one path,
`while`, `for`, `do-while`, ternary — `src/lumen_check_assign.zig:173`,
`src/lumen_check_expr.zig:450`, `src/lumen_check_stmt.zig:919,937,950,1141`)
and two through `failUnknownMethod` for `array`/`string` (the third
`failUnknownMethod` call site, `container.invalid.unknown-method`, is a
false positive for this bug — see Group B, it's stale for an unrelated
reason: `.clear()` is now a real method).

| Case | Fixture line | Expected | Actual |
|---|---|---|---|
| `native.invalid.if-condition-type` | `if (1) { ... }` | `E_TYPE_MISMATCH` | `` if` condition must be `boolean`, got `i32` — truthiness is not supported; write `x != 0` `` (no code) |
| `native.invalid.else-if-condition-type` | `} else if ("mid") { ... }` | `E_TYPE_MISMATCH` | same shape, `` got `string` `` |
| `native.invalid.while-condition-type` | `while (1) { ... }` | `E_TYPE_MISMATCH` | same shape |
| `native.invalid.for-condition-type` | `for (let i = 0; i + 5; ...)` | `E_TYPE_MISMATCH` | same shape, `` got `i32` `` |
| `native.invalid.do-while-condition-type` | `} while ("again");` | `E_TYPE_MISMATCH` | same shape, `` got `string` `` |
| `native.invalid.ternary-condition-type` | `let label = "yes" ? 1 : 0;` | `E_TYPE_MISMATCH` | `` `?:` condition must be `boolean`, got `string` — ... `` (no code); a second, correct cascade error (`undefined variable 'label'`) follows |
| `string.invalid.unknown-method` | `s.reverse()` (`s: string`) | `E_TYPE_MISMATCH` | `` `string` has no method 'reverse' `` (no code) |
| `array.invalid.unknown-method` | `xs.flatten(...)` (`xs: int[]`) | `E_TYPE_MISMATCH` | `` `array` has no method 'flatten' `` (no code), plus a correct cascade error |

**Reason (all 8, one line):** the checker still rejects the exact same
program for the exact same reason; the human-readable message it builds
just never got the `[E_TYPE_MISMATCH]` suffix that spec 218 promises every
diagnostic keeps, unlike every sibling formatted diagnostic in the same
file.

---

## Group B — stale fixtures/manifests (fixture or manifest fix needed)

| Case | Fixture line | Expected | Actual | Why stale |
|---|---|---|---|---|
| `native.invalid.arithmetic-type` | `let value = 1 + "x";` | `E_TYPE_MISMATCH` | compiles (unused-var warning only) | Spec 142 ("string + number concatenation (TS semantics)", `e4511e7`): `+` with either side a string is now valid concat; non-string side is stringified. This exact expression (`1 + "x"` → `"1x"`) is spec 142's own worked example. |
| `native.invalid.string-concat-type` | `let bad = "count: " + 1;` | `E_TYPE_MISMATCH` | compiles | Same spec 142 — this line *is* spec 142's canonical "was `E_TYPE_MISMATCH`, now compiles" example (`specs/142-string-number-concatenation/spec.md`: `"a" + 1 // "a1" (was E_TYPE_MISMATCH)`). |
| `native.invalid.compound-assignment-type` | `let name = "agent"; name += 1;` | `E_TYPE_MISMATCH` | compiles | Same spec 142 feature, applied consistently to `+=` (`src/lumen_check_stmt.zig:864-873`): a string LHS with a numeric/bool RHS stringifies the RHS instead of erroring. |
| `native.invalid.throw-type` | `throw "boom";` | `E_THROW_TYPE` | compiles | Spec 249 ("CLI version/help/unknown-command + string throws", `a42f63471`): `throw <string>` is now deliberately accepted — "an Error carries a string message at runtime, so the lowering is identical." |
| `error.invalid.throw-string` | `try { throw "boom"; } catch (e) { ... }` | `E_THROW_TYPE` | compiles | Same spec 249. Also makes spec 019's own FR-001/SC-002 ("Throwing a string ... fail[s] before native build") stale — spec 019 predates spec 249 and was never reconciled with it. |
| `native.invalid.math-unsupported` | `let bad = Math.random();` | `E_UNSUPPORTED_STD` | compiles | `Math.random()` was intentionally implemented (`38fad8f0`, "feat: Math.random() returns a pseudo-random f64 in [0, 1)") — checker (`src/lumen_check_stdlib.zig:1104`) and emitter (`src/lumen_emit_static.zig:50`) both support it now. This is exactly CLAUDE.md's own worked example of "a missing stdlib function is a thing to write" — done correctly, fixture never updated. |
| `container.invalid.unknown-method` | `let m: Map<string, int> = new Map(...); m.clear();` | `E_TYPE_MISMATCH` | compiles | `Map`/`Set.clear()` was intentionally implemented (`d8400658`, "collections: Map/Set clear (spec 088)") — `src/lumen_check_methods.zig:490,580`. Not part of the Group-A message-formatting bug: this one genuinely compiles clean, no diagnostic at all. |
| `array.invalid.reduce-arg-count` | `xs.reduce((acc, x) => acc + x);` (1 arg) | `E_ARG_COUNT` | compiles | Spec 132 ("reduce/reduceRight without an initial value", `0e513d5`): single-argument `reduce`/`reduceRight` (no seed) is now valid, JS-matching behavior — the first element seeds the accumulator. `src/lumen_check_methods.zig:161-165` only rejects 0 or 3+ args now. |
| `native.invalid.function-return-type` | `function bad(): int { return "nope"; }` | `E_RETURN_TYPE` | `type mismatch: expected \`i32\`, got \`string\` [E_TYPE_MISMATCH]` | Spec 218 ("readable diagnostics with type detail", `7fae0d2`) explicitly consolidated this case: "`failTypeMismatch`... used by every `ensureAssignable` mismatch path plus the return-statement and ternary branch checks." `E_RETURN_TYPE` is still live but now fires only for a bare `return;` with no value where one is required (`src/lumen_check_stmt.zig:1415`) — a different scenario. Spec 001's own doc table (`spec.md:305`, "`E_RETURN_TYPE`: Produced when a function returns a value incompatible with its declared return type") is equally stale and should be corrected alongside the manifest. Unlike Group A, the actual message here *does* carry a bracketed code — just a different, deliberately-renamed one. |
| `native.invalid.dynamic-property-write` | `let user = { id: 1 }; user["name"] = "Ada";` | `E_DYNAMIC_PROPERTY_WRITE` | `` indexed assignment (`x[i] = ...`) is not supported — arrays and records are immutable; build a new value instead (...) `` (no code) | Spec 342 ("clearer immutability diagnostics for indexed and array writes", `7b2aeeb`) explicitly moved bracket/index writes (`obj["k"] = v`, same as `a[0] = 9`) off the `E_DYNAMIC_PROPERTY_WRITE` code onto this dedicated, deliberately code-less message — spec 342's own text: "the lexical indexed-write guard emits an index-specific message rather than the `E_DYNAMIC_PROPERTY_WRITE` record code." Dot-notation field writes (`user.name = "Ada"`, `src/lumen_check_stmt.zig:327`) still use the bare, still-bracketed `E_DYNAMIC_PROPERTY_WRITE`. |
| `decorators.invalid.argument-is-not-an-expression` | `let name = "agents"; @entity(name) class Agent { ... }` | `E_DECORATOR_ARG` | `` '@entity' is not imported — a decorator is an ordinary imported function, so add `import { entity } from "./…";` [E_DECORATOR] `` | Two compounding staleness issues. (1) The fixture never imports `entity` (spec 455 has required decorators to be ordinary imports since its own inception — see `spec.md:207-217`), so the unrelated-but-correct "not imported" check (`E_DECORATOR`, `src/lumen.zig:1110`) fires first and masks the intended check entirely. (2) Even fixed up with a real import, the chosen "bad" argument — a bare identifier, `name` — is not actually rejected: `parseDecoratorArg` (`src/lumen_parser_decl.zig:44-51`) intentionally accepts a bare identifier as decorator-arg syntax (the `.ident` variant, `src/lumen_ast.zig:33-38`, "a bare name — `@Guard(needsPg)` ... What it buys is that the checker resolves it"), added to support `@Guard(fnName, ...)`-style name-application decorators used by a downstream package. Verified directly: `@entity(name)` with a correct import and a correctly-shaped `entity.ts` passes parsing cleanly (fails later, on an unrelated decorator-signature check); `@entity(1 + 2)` with the same import correctly reports `E_DECORATOR_ARG`. The fixture needs both a real import and a genuine non-literal expression (e.g. `1 + 2`, or a call) to actually exercise `E_DECORATOR_ARG` again. |

## Not investigated further

Root-causing every Group-B commit to its exact spec number was done via
`git log -p -S<snippet>` against the actual message/behavior text, not by
reading every commit in full; the dates and spec numbers cited above are
what the search surfaced and were cross-checked against the cited
`specs/*/spec.md` where one exists. No fixture, manifest, or checker source
was modified as part of this investigation, per CLAUDE.md's "Do not migrate
fixtures to make a suite pass."

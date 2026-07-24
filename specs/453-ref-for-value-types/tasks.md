# Tasks: Ref For Arrays And Strings

## Investigation

- [x] Confirm every site that consults `isRefAllowed` / `isRefScalar`
      (`src/lumen_types.zig:586`, `:595`) and what each does with the answer.
- [x] Trace how a `Ref` parameter is emitted end to end: the `*T` signature
      (`src/lumen_emit_stmt.zig:519`, `:563`, `src/lumen_emit_class.zig:313`),
      the call-site address-of (`src/lumen_check_expr.zig:2147-2153`), and where
      the scalar `.*` deref is inserted in a body.
- [x] Determine how `a.length` and `a[i]` are emitted for a plain array
      parameter, and what each would need for a `*[]T`.
- [x] Confirm what `bodyReassignsBinding` (`src/lumen_emit_analysis.zig:356`)
      does for a non-`Ref` parameter today, so the `Ref` path is not confused
      with the copy it currently forces.

## D1 — accept arrays and strings

- [x] `isRefAllowed` accepts an array of any element type.
- [x] `isRefAllowed` accepts `string`.
- [x] `Ref<T>[]` as a rest parameter stays rejected. Reported as "unknown
      generic type" rather than E_REF_TARGET, because the annotation is parsed
      as an array of a generic named `Ref` before the Ref marker is recognised.
      Rejected either way; the wording is a follow-up.
- [x] A class, map, set or promise stays rejected, with the diagnostic naming
      the reason that is actually true of them.

## D2 — deref

- [x] `isRefScalar` accepts arrays and strings, so bodies deref them.
- [x] Whole-value assignment (`a = [...a, x]`) writes through the pointer.
- [x] `a.push(x)` writes through the pointer, being the same rebinding.
- [x] `a.length` reads the caller's current length.
- [x] `a[i]` reads the caller's current element.
- [x] A method that returns a new array (`sort`, `reverse`, `slice`) reads
      through the pointer and leaves the caller's value alone unless assigned.
- [x] Passing a `Ref<T[]>` parameter on to another `Ref<T[]>` parameter.

## D3 — diagnostics and comments

- [x] `E_REF_TARGET`'s message names the accepted and rejected categories in
      terms of the language, not of representation.
- [x] The doc comments at `src/lumen_types.zig:583-585` and
      `src/lumen_check.zig:1256-1258` stop calling arrays and strings
      reference-like.

## Tests

- [x] R1: accumulating into a `Ref<int[]>` prints 2.
- [x] R2: a `Ref<string>` out-parameter carries a file's contents back.
- [x] `push` through a `Ref` parameter is visible to the caller.
- [x] `length` and indexing inside the callee see the caller's value.
- [x] An array of records as a `Ref` target, with a field read through it.
- [x] An array of arrays as a `Ref` target.
- [x] A `Ref<T[]>` passed on to a second `Ref<T[]>` parameter.
- [x] A plain array parameter still copies: `push` stays invisible to the
      caller. This is the regression guard for the model, not a wish.
- [x] `a[i] = x` still rejected through a `Ref` parameter.
- [x] `Ref<T>[]` rest parameter still rejected.
- [x] `Ref<Map<string,int>>` still rejected, with the corrected message.

## Gates

- [x] `zig build` and `zig build test` pass.
- [x] One clean `zig build conformance` run: 195 passed / 50 failed against
      main's 186 / 50. The 50 failing case names were diffed against main's and
      are identical; the difference is the eight new cases plus one main cannot
      run.
- [x] Existing `Ref` examples and spec cases behave unchanged, since
      `isRefScalar` now answers differently for two more types.
- [x] New examples land as conformance cases with a manifest wired into
      `build.zig`.


## What the work actually turned on

Widening `isRefAllowed` and `isRefScalar` was the easy half and behaved as the
spec predicted. The real defect was elsewhere.

A `let s = ""` or `let a = []` that is only ever appended to is compiled to a
growable buffer instead of a slice — the string-builder optimisation in
`lumen_opt.zig`, which makes an O(n) build out of what would otherwise be
O(n^2). Its own comment says the analysis bails on `Ref`, and `accBadRef` does
check for a `Ref` deref read. It did not check for the binding being *passed*
to a `Ref` parameter, because until this slice no array or string could be one.

So the accumulator transform typed the local as a growable `[]u8`/`[]i32` while
`Ref` expected a pointer to the ordinary `[]const u8`/`[]const i32`, and the
backend rejected the call:

    expected type '*[]const i32', found '*[]i32'

The fix is four lines in `accBadRef`: a call argument that lands on a `Ref`
parameter disqualifies the binding from the transform. The checker already
records which arguments those are, in the call node's `ref_args`, so no new
plumbing was needed.

Worth noting the shape of the failure — it was a compile error naming Zig
types, not a miscompile. Loud, but it points at generated code rather than at
the program, which is the same class of diagnostic gap seen in specs 451 and
452.

## Follow-up (not this slice)

- [ ] Report a rest `Ref<T>[]` as E_REF_TARGET rather than "unknown generic
      type", which is what the annotation parser reaches first.
- [ ] Decide whether a mutating method call on a non-`Ref` array parameter
      should be rejected or warned about. It is the trap this spec routes
      around rather than closes, and it would be the language's first
      diagnostic aimed at a mental model rather than a type error.
- [ ] `Ref<T>` for maps, sets, promises and classes, where only whole-value
      rebinding is missing.
- [ ] Rebinding a `Ref<record>` as a whole, which fails today with "cannot
      assign to constant".
- [ ] std-contrib `ai`: revisit `rag/split.ts`, whose recursive descent
      concatenates a returned array at every level because there was no way to
      accumulate into one.

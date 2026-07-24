# Tasks: Ref For Arrays And Strings

## Investigation

- [ ] Confirm every site that consults `isRefAllowed` / `isRefScalar`
      (`src/lumen_types.zig:586`, `:595`) and what each does with the answer.
- [ ] Trace how a `Ref` parameter is emitted end to end: the `*T` signature
      (`src/lumen_emit_stmt.zig:519`, `:563`, `src/lumen_emit_class.zig:313`),
      the call-site address-of (`src/lumen_check_expr.zig:2147-2153`), and where
      the scalar `.*` deref is inserted in a body.
- [ ] Determine how `a.length` and `a[i]` are emitted for a plain array
      parameter, and what each would need for a `*[]T`.
- [ ] Confirm what `bodyReassignsBinding` (`src/lumen_emit_analysis.zig:356`)
      does for a non-`Ref` parameter today, so the `Ref` path is not confused
      with the copy it currently forces.

## D1 — accept arrays and strings

- [ ] `isRefAllowed` accepts an array of any element type.
- [ ] `isRefAllowed` accepts `string`.
- [ ] `Ref<T>[]` as a rest parameter stays rejected.
- [ ] A class, map, set or promise stays rejected, with the diagnostic naming
      the reason that is actually true of them.

## D2 — deref

- [ ] `isRefScalar` accepts arrays and strings, so bodies deref them.
- [ ] Whole-value assignment (`a = [...a, x]`) writes through the pointer.
- [ ] `a.push(x)` writes through the pointer, being the same rebinding.
- [ ] `a.length` reads the caller's current length.
- [ ] `a[i]` reads the caller's current element.
- [ ] A method that returns a new array (`sort`, `reverse`, `slice`) reads
      through the pointer and leaves the caller's value alone unless assigned.
- [ ] Passing a `Ref<T[]>` parameter on to another `Ref<T[]>` parameter.

## D3 — diagnostics and comments

- [ ] `E_REF_TARGET`'s message names the accepted and rejected categories in
      terms of the language, not of representation.
- [ ] The doc comments at `src/lumen_types.zig:583-585` and
      `src/lumen_check.zig:1256-1258` stop calling arrays and strings
      reference-like.

## Tests

- [ ] R1: accumulating into a `Ref<int[]>` prints 2.
- [ ] R2: a `Ref<string>` out-parameter carries a file's contents back.
- [ ] `push` through a `Ref` parameter is visible to the caller.
- [ ] `length` and indexing inside the callee see the caller's value.
- [ ] An array of records as a `Ref` target, with a field read through it.
- [ ] An array of arrays as a `Ref` target.
- [ ] A `Ref<T[]>` passed on to a second `Ref<T[]>` parameter.
- [ ] A plain array parameter still copies: `push` stays invisible to the
      caller. This is the regression guard for the model, not a wish.
- [ ] `a[i] = x` still rejected through a `Ref` parameter.
- [ ] `Ref<T>[]` rest parameter still rejected.
- [ ] `Ref<Map<string,int>>` still rejected, with the corrected message.

## Gates

- [ ] `zig build` and `zig build test` pass.
- [ ] One clean `zig build conformance` run: no new failures against the
      186 passed / 50 failed baseline.
- [ ] Existing `Ref` examples and spec cases behave unchanged, since
      `isRefScalar` now answers differently for two more types.
- [ ] New examples land as conformance cases with a manifest wired into
      `build.zig`.

## Follow-up (not this slice)

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

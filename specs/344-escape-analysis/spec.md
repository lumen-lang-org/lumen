# Spec 344 — Escape analysis: stack-allocate non-escaping class instances

## Goal

Construct a `const v = new C(...)` on the stack instead of the scratch arena when
the instance provably never leaves its function. Lumen has no garbage collector,
so short-lived object churn otherwise grows memory and dominates alloc-heavy
loops (the Node-vs-Lumen benchmark's weak spot). This is the compiled-language
answer: prove non-escape at compile time, drop the heap allocation entirely.

## Soundness rule (conservative)

A `const`/`let` local bound directly to `new C(args)` is stack-allocated iff:

1. `C` is a non-generic class with no container type (not Map/Set/Error/…), and
   its constructor chain does not throw (a throwing ctor keeps the heap path).
2. **`C` never leaks `self`.** Across `C` and its ancestors, no method returns a
   class type (which could be `return this`), and within every method body and
   the constructor body `this` appears only as the receiver of a field read or a
   method call.
3. **The binding never escapes.** Every occurrence of the name is the immediate
   receiver of a field read (`v.f`) or a method call (`v.m(...)`) — never bare:
   not an argument, return value, array/object element, assignment, index,
   `new`/call/method argument, `super(...)` argument, or closure capture. The
   name must be declared exactly once in the function (no shadowing).

A false "escapes" only forgoes the optimization, so the analysis errs toward
heap allocation. Passing an instance as an argument (even to a method that only
reads it) is treated as escaping — closing that needs interprocedural analysis
(future work).

## Behavior

Non-escaping instances build in place and cost no heap allocation and no cleanup;
program results are identical. Escaping instances (returned, stored in a field,
captured, passed as an argument) keep the arena `__init` path unchanged.

## Implementation

- `src/lumen_ast.zig`: `VarDecl.stack_alloc`.
- `src/lumen_escape.zig`: the analysis — `exprEscapes`/`thisEscapes` receiver-rule
  walkers over expressions and statements, `classSelfSafe`, and `analyze` which
  marks eligible `var_decl`s. Runs at the end of `checkProgram`, after all method
  return types (including generic specializations) are resolved.
- `src/lumen_emit_class.zig`: a value-returning constructor `__initv` (builds a
  stack `var self: C` and returns it by value) alongside the heap `__init`.
- `src/lumen_emit_stmt.zig`: a `stack_alloc` var-decl emits
  `var __stk = C.__initv(args); const v = &__stk;` (heap fallback for a throwing
  ctor).

## Verification

- `zig build` and `zig build test` green.
- Non-escaping (`const a = new Vec(3,4); a.dot(a)`) stack-allocates (generated
  code uses `__initv` + `&__stk`, no `__sa().create`); escaping-via-return and
  escaping-via-field-store keep the heap path; all produce correct results.
- Benchmark (`bench/`, 20M iters): a fully receiver-only temp loop drops from
  ~all-heap (~1.5 s, memory-growing) to **~280 ms — faster than Node 22 (~360 ms)
  and with no GC jitter**. A loop where one of two temps still escapes (passed as
  an argument) improves ~2–4×.

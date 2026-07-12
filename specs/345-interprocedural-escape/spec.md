# Spec 345 — Interprocedural escape analysis (non-capturing parameters)

## Goal

Extend escape analysis (spec 344) so an instance passed as an argument can still
be stack-allocated when the callee does not capture that parameter. This
recovers the common `a.op(b)` shape (`b` is read, not stored).

## Motivation

Spec 344 treated any instance passed as an argument as escaping, so
`const b = new Vec(...); a.dot(b);` kept `b` on the heap even though `dot` only
reads `o.x`/`o.y`. The benchmark's second temp stayed heap-allocated. Proving the
callee's parameter is non-capturing lets the caller stack that instance too.

## Behavior

A first pass computes, for every function and method, which parameters escape
their body (a parameter that appears bare, is returned, stored, captured, or —
conservatively — passed to another call). The binding pass then treats an
instance passed as argument `i` to `f`/`C.m` as **non-escaping** when parameter
`i` of the resolved callee is non-capturing (method lookup walks the inheritance
chain). Unknown callees and rest/extra positions stay conservatively escaping.
The parameter-capture pass itself runs with interprocedural resolution off, so it
needs no fixpoint and remains sound.

Results are unchanged; only the allocation strategy improves.

## Implementation

- `src/lumen_escape.zig`:
  - `computeCaptures` precomputes a per-parameter capture array for each
    function/method, keyed by `fn\0name` / `m\0class\0method`.
  - `exprEscapes`'s `.method_call` and `.call` cases became index-aware: a bare
    instance argument is safe iff the resolved callee's parameter at that index
    is non-capturing (`methodCaptures` resolves up the inheritance chain).
  - `analyze` runs the capture pass, then the binding pass with interprocedural
    resolution enabled.

## Verification

- `zig build` and `zig build test` green.
- `const b = new Vec(...); a.dot(b)` now stack-allocates `b` (generated code
  shows both temps via `__initv`/`&__stk`, only the unused `__init` retains
  `create`); results are identical.
- Benchmark (`bench/`, 20M iters, two temps where one is passed to `dot`): with
  both temps now stack-allocated the loop drops from ~1.3–3.5 s (all-heap) to
  **~290 ms — faster than Node 22 (~385 ms), with no GC jitter.**

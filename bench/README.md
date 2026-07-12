# Lumen vs Node.js micro-benchmarks

Two matched programs run on both runtimes. Each exercises features added this
session — inferred-return functions, inferred class fields, `this`-based method
return inference, and method dispatch — and is written so the `i32` arithmetic
stays in range, making the output **bit-identical** on both runtimes.

- Lumen: compiled to a native binary with `lumen compile --release-fast`.
- Node: `node bench*.mjs` (V8, JIT).
- Times are wall-clock of the whole process (includes each runtime's startup).
  Machine: this container; Node v22, Lumen native release-fast.

## Results

| Workload | Lumen (native) | Node 22 (V8) | Winner |
|---|---|---|---|
| **Startup** — trivial `console.log` | ~3 ms | ~53 ms | **Lumen ~17× faster** |
| **Allocation-free compute** — `bench2`, 100M iters (arithmetic + method dispatch, one reused instance) | ~929 ms | ~1124 ms | **Lumen ~1.2× faster** |
| **Object churn, escape-analyzable** — `bench3`, 20M iters (one `new P` per iter, used only as a method receiver) | **~280 ms** | ~360 ms | **Lumen ~1.3× faster** |
| **Object churn, both temps escape-analyzed** — `bench`, 20M iters (two `new Vec` per iter; one is passed as an argument to a non-capturing method) | **~290 ms** | ~385 ms | **Lumen ~1.3× faster** |

Outputs are identical on both runtimes (`bench` → 516810114, `bench2` → 18723,
`bench3` → 144999087).

## Escape analysis (spec 344)

`bench3` and `bench` both allocate short-lived objects — historically Lumen's
weak spot (no GC; the arena grows and never frees within a run). **Escape
analysis** now proves when a `new C(...)` never leaves its function and builds it
on the stack instead:

- `bench3`'s temp is used only as a method receiver → **fully stack-allocated,
  zero heap in the hot loop**. It went from ~all-heap (~1.5 s, memory-growing) to
  **~280 ms, beating Node** — and with no GC jitter (280/280/281 ms vs Node's
  variance).
- `bench`'s second temp is passed as an argument (`a.dot(b)`). **Interprocedural
  escape analysis** (spec 345) proves `dot` doesn't capture its parameter, so
  that temp is stack-allocated too — the loop is now fully heap-free and drops
  from ~1.3–3.5 s (all-heap) to **~290 ms, beating Node.** An argument passed to
  a callee that *does* store it (or an unknown callee) stays conservatively on
  the heap.

## Reading the results

- **Native start-up wins decisively.** No interpreter/JIT to spin up: a Lumen
  binary is running user code in a few milliseconds, versus ~50 ms for Node.
  For short-lived CLIs this dominates.
- **Pure compute favors native.** With no allocation in the hot loop, Lumen's
  ahead-of-time native code edges out V8's JIT (~1.2×) — no warm-up, no
  deopt risk, method calls lower to direct calls on a flat struct.
- **Short-lived object churn favors V8.** Lumen has no garbage collector; class
  instances allocate and are not reclaimed within a run, so a loop that creates
  millions of throwaway objects grows memory and slows down. V8's generational
  GC is purpose-built for exactly this. Idiomatic Lumen avoids the churn — reuse
  instances, keep values in scalars, and prefer `map`/`reduce` over rebuilding
  objects per iteration (the language's immutability already nudges this way).

## Run it

```sh
# Lumen native
lumen compile --release-fast bench2.ts && ./bench2
# Node
node bench2.mjs
```

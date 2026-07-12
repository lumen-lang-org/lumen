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
| **Allocation-heavy** — `bench`, 20M iters (2 short-lived `new Vec` per iter) | ~1.3–3.5 s | ~0.38 s | **Node ~3–9× faster** |

All three produce identical output on both runtimes
(`bench` → 516810114, `bench2` → 18723).

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

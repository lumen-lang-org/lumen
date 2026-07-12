# 356 — Refactor: split oversized source files by domain

## Problem

Three files had grown far past a maintainable size:

| file | lines |
|------|-------|
| `src/lumen_check_stdlib.zig` | 3720 |
| `src/lumen_compiler.zig`     | 3216 |
| `src/lumen_emit.zig`         | 2332 |

Each mixed several independent concerns (instance-method checking vs
namespace dispatch; parser/pipeline orchestration vs a thousand lines of
runtime-prelude string blocks; expression codegen vs one 1021-line switch
arm), so unrelated changes always collided in the same file.

## Change — pure code moves, no behavior change

1. **`lumen_check_stdlib.zig` → three modules.**
   - `lumen_check_methods.zig` (1070): instance methods on builtin receivers
     (arrays, Map/Set, strings, Buffer, sockets, streams, EventEmitter,
     numbers, Hash/Hmac). `cbParamsMatch` made pub for the one external use.
   - `lumen_check_stdlib_os.zig` (1392): OS-facing namespaces — `fs`, `path`,
     `process`, `os`, `child_process`, `readline` — with their `registerLumen*`
     record helpers.
   - `lumen_check_stdlib.zig` (1297): the `staticCallType` dispatcher and the
     remaining namespaces (Math/String/Array/JSON/http/net/crypto/...).
   The `Checker` aliases in `lumen_check.zig` repoint, so every
   `self.fooCallType(...)` call site is untouched.

2. **`lumen_compiler.zig` (3216 → 839) → runtime emitters.** The gated
   `if (program.needs_*)` prelude blocks moved verbatim, same order:
   - `lumen_runtime_fs.zig` (1075): async fs, `fs.*Sync`, fd APIs, `fs.watch`,
     file streams, worker threads. Takes `decls` as a parameter for the one
     mid-sequence `decls.items` splice.
   - `lumen_runtime_os.zig` (843): stdio streams, readline, Buffer, path, URL,
     child_process, assert, time, console-to-stdout; process/os APIs, crypto,
     zlib, httpget, serve.
   - `lumen_runtime_net.zig` (517): http client module, concurrent
     `http.createServer` runtime, net sockets, HTTP constants, JSON.
     Recomputes `needs_http_threadpool` locally from program+options.

3. **`lumen_emit.zig` (2332 → 1313).** `emitExpr`'s `.static_call` arm
   (1021 lines) moved verbatim to `lumen_emit_static.zig`
   (`emitStaticCall`); the arm is now a one-line dispatch. The module-level
   codegen counters the arm mutates (`g_global_pred_seq`, ...) are now pub.

No file is over 2000 lines; the largest is `lumen_check_expr.zig` (1978).

## Verified

`zig build` + `zig build test` green after each of the three splits
(committed separately). Runtime probes across every moved surface:
array map/sort/join, string methods, `Math.*`/`String.*`/`JSON.*` static
calls, `fs.readFileSync`, `path.basename`, `process.platform`, and the
`http.createServer` benchmark server still compiles under `--release-fast`.

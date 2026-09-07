# Tasks: 508 blocking I/O and threads on the Node target

**Input**: spec.md, its Decision and Spike sections. **Depends on**: 504–507
(the emitter, byte strings, test runner, and FFI link — all done).

## Phase 1: The broker, promoted from spike to runtime

- [x] T001 Move the spike's protocol into `packages/node-runtime/lib/broker/`
  as a real module (`protocol.mjs`, `broker.mjs`, `sync_bridge.mjs`), not a
  throwaway script: exported functions, no top-level side effects beyond
  what `lib/net.mjs`/`lib/http.mjs`/etc. call into.
- [x] T002 Fix the spike's two found gaps for real: `process.sleep` re-arms
  a follow-up timer if `setTimeout` undershoots the requested duration
  (spike found a 0.34ms undershoot on one of three runs); replace
  `JSON.stringify`/`parse` argument encoding with a small fixed-layout
  binary encoding per op (the spike measured 1.3–2.8ms/call overhead,
  worth cutting before it's load-bearing for `http.stream`'s per-chunk
  reads).
- [x] T003 One control block and one broker worker per program (not per
  call site): `lib/broker/singleton.mjs` lazily starts the worker on first
  use, shared by every blocking call the program makes.

## Phase 2: The blocking surfaces, per the spec's Decision

- [x] T004 `process.sleep(ms)`: broker op, `sync_bridge` wrapper.
- [x] T005 `net.connect`/`Socket.read()`/`Socket.write()`/`Socket.close()`
  (054): broker owns the real `net.Socket`; mirror the spike's connect/read
  exactly, including the same-synchronous-turn listener rule the spike
  found necessary. Done: `lib/net.mjs`'s `Socket` class, broker's unified
  handle table (`kind: "socket"`), `unsupportedStaticCall` relaxed for
  `net.connect` (createServer stays refused, T010). A failed connect never
  throws — a dead handle (`-1`), mirroring `LumenSocket`'s null-stream
  fallback exactly, unlike the earlier throw-by-name stub. Tests:
  `tests/net.test.mjs`.
- [x] T006 `http.request`/`http.stream(...).read()` (042, 452): broker owns
  a `http.request`; response headers and body chunks cross the bridge the
  same way socket reads do. Done in full: `request`/`get` (one buffered
  round trip, `OP_HTTP_REQUEST`) and `stream` (`status`/`header`/`readLine`/
  `read`/`write`/`done`/`close`, `OP_HTTP_STREAM_OPEN` + the generic
  read/readline/write/close ops) both wired, both degrading to a dead
  handle/`{status:-1,ok:false}` on failure rather than throwing, mirroring
  `LumenHttpStream`/`__httpRequest`. Tests: `tests/http.test.mjs`.
- [x] T007 `child_process.spawn(...).readLine()` (450): broker owns the
  child process; line-buffer stdout in the broker (mirroring the native
  `LumenChildProcess` handle) so `readLine()` returns one line per call
  the same way natively. Done: `lib/child_process.mjs`'s `ChildProcess`
  class (`write`/`writeLine`/`readLine`/`close`); `close()` flushes/closes
  stdin then blocks for the child's actual exit (matches
  `LumenChildProcess.close` — it does not kill), never a forced kill. A
  failed spawn degrades to a dead handle, never throws. Tests:
  `tests/child_process.test.mjs` (a 2000-line `cat` round trip; the spec's
  own 10k-line case is `508.spawn-readline-roundtrip` below).
- [x] T008 `readline.question` (058): decided NOT to use the broker —
  `question` never takes a timeout, and stdin's existing blocking
  `readLine()` (`lib/streams.mjs`, spec 046/053) already blocks this thread
  correctly via `fs.readSync` with no timer or second process involved, so
  there is nothing the broker would add. Recorded in `lib/readline.mjs`'s
  own comment; no code change needed (`tests/readline.test.mjs` already
  covers it).

  **Real bug found and fixed along the way (not itself a task, but load-
  bearing for T005-T007)**: `globals.mjs` replaces `globalThis.Buffer` with
  Lumen's own `LumenBuffer` (spec 056) on whichever thread installs it —
  which includes the broker's own worker thread whenever a program is run
  as `node --import .../globals.mjs prog.ts` (Node workers inherit
  `process.execArgv`, which carries `--import`, unless told otherwise).
  `LumenBuffer.from` doesn't support the 3-argument
  `Buffer.from(arrayBuffer, byteOffset, length)` form the wire decoders use,
  so it silently decoded the *whole* argument buffer instead of the
  requested field — found via `child_process.spawn("cat", [])` receiving a
  garbled command under exactly that invocation shape, the same shape
  `tests/helpers.mjs`'s `runProgram` (used throughout this package's other
  test files) and a hand-run `.ts` file both use. Fixed by explicitly
  importing the real `node:buffer` `Buffer` in
  `lib/broker/{protocol,broker,singleton,sync_bridge}.mjs` instead of
  relying on the ambient global — see `protocol.mjs`'s own comment.

## Phase 3: Worker.run and the server rejection

- [x] T009 `Worker.run(fn)` (059): a `worker_threads` Worker running the
  emitted module, `fn` selected by name, scalar-only result via message
  passing — no broker involved (spec's Decision point 2). Done, exactly on
  the design the earlier deferral note above sketched: `Worker.run`'s call
  site (`emitWorkerRun`, `lumen_emit_js_expr.zig`) becomes a descriptor —
  `Worker.run({ moduleUrl, fnName, args })` — instead of the raw function
  value, since a JS closure cannot cross a `worker_threads` boundary as a
  live value. Two accepted shapes, matching 059's own restriction, checked
  before emitting:
  - **A plain top-level function** (`Worker.run(someFn)`): its own module
    is forced to export it (`emitProgram`'s new `worker_run_targets`/
    `worker_target_modules` pass — `refsInExpr`'s `.static_call` case
    records the name as a side effect of the reference walk every call's
    args already get, so this needed no new traversal), even when nothing
    else in the program ever imports it.
  - **An arrow capturing only scalar outer bindings**: hoisted into a
    synthesized, exported top-level function in the *same* module (`
    e.hoisted`, flushed once after that module's ordinary statements — JS
    `function` declarations hoist within their scope regardless of source
    position), its captures as explicit parameters. A `this` capture or a
    non-scalar one is rejected at compile time
    (`E_TARGET_UNSUPPORTED`, naming the two accepted shapes) rather than
    failing obscurely once shipped across the boundary.

  Reused `arrow.captures` as the earlier note expected, but `Capture` only
  carried `emit_name` — the *native* backend's mangled closure-storage
  name, meaningless to the JS target, which always emits a `var_ref`'s own
  plain source name. Added `Capture.name` (`lumen_ast.zig`, populated at
  both existing append sites in `lumen_check_expr.zig`) rather than derive
  it by string-parsing `emit_name`. Confirmed this was the actual failure
  mode, not a hypothetical one: the first working build emitted
  `args: [__lumen_0_base, ...]`, an identifier that does not exist in the
  surrounding JS scope, caught by actually running the compiled output, not
  by reading the diff.

  The re-run-every-top-level-statement concern in the earlier note is real
  and stays real — the worker thread's `import(moduleUrl)` does re-execute
  that module's top-level code once — but is a documented consequence of
  059's own module-state restriction (its scalar-only capture rule already
  assumes a Worker.run body doesn't depend on shared module state), not a
  new problem this task introduces; noted in `lib/worker_bootstrap.mjs`'s
  own comment rather than solved by adding a module-instantiation guard
  nothing else needs yet.

  `lib/worker.mjs` now spawns a real `worker_threads.Worker` per call
  against `lib/worker_bootstrap.mjs` (imports `../globals.mjs` first, since
  a fresh thread has nothing on its own `globalThis` yet, then the target
  module, then calls the named export and posts the result back).
  Conformance: `specs/508-node-blocking-io/examples/valid/worker_run.ts`
  (plain function, scalar-capturing arrow, two concurrent calls) prints
  identically on both targets — `508.worker-run.node`/`.native`.
- [x] T010 `net.createServer`/`http.createServer`: `E_TARGET_UNSUPPORTED`
  naming this spec, per the Decision's point 3. Done:
  `unsupportedStaticCall` (src/lumen_emit_js_stdlib.zig) now refuses only
  `net.createServer`/`http.createServer` (`Worker.run` was on this list
  until T009 wired it up for real) instead
  of every name in those namespaces; `lib/net.mjs`/`lib/http.mjs` throw the
  same message by name for a hand-called JS test. Diagnostics conformance
  cases: `508.unsupported.net-create-server`,
  `508.unsupported.http-create-server` (below) — plus spec 504's own
  `node.unsupported.net-server` case, updated from `net.connect` (now
  supported, T005) to `net.createServer` (still refused) since it was
  pinning the exact behavior this task changes.

## Phase 4: Conformance and Joule

- [x] T011 Conformance manifest (`specs/508-node-blocking-io/conformance/
  manifest.json`): `process.sleep(250)` measures >= 250ms (SC-002, guarded
  by T002's fix, `508.sleep.*`, both targets); a `readLine()` loop over
  `spawn("cat")` round-trips 10k lines without drift
  (`508.spawn-readline-roundtrip.*`, both targets); `net.createServer` and
  `http.createServer` report `E_TARGET_UNSUPPORTED` (SC-003,
  `508.unsupported.*`, both targets, node-diagnostics + native static). All
  8 cases pass.
- [ ] T012 Joule spec 004 T003 (`make node`, `make node-test`): with T004–T009
  landed, `code.ts` clears every `E_TARGET_UNSUPPORTED`. Confirmed directly
  (joule-sh/code was attached this session): `lumen compile --target node
  src/code.ts` compiles Joule's real, full 290-file entry point with zero
  errors (only pre-existing unused-variable warnings), and `node
  code.node/code.mjs --version` runs and prints the real version string.
  Past `--version`, `node code.node/code.mjs` crashes inside
  `runDaemonJoule` — not an unsupported-construct error, a real bug this
  round found and filed as spec 509 (`import { x as y }` dropped by the
  node emitter; `src/terminal/attach.ts`'s aliased `workspaceRoot` import
  collides with a same-named local once the alias is gone). `make node`/
  `make node-test`/`node-skip.txt` itself is still Joule's own work
  (joule-sh/code, spec 004 T003) — not attempted here since it needs 509
  fixed first to get past the daemon path, and this round's remit is 508's
  own tasks, not Joule's.
  itself (confirmed: no `code.ts`, no `joule` source tree anywhere in this
  checkout). Needs a human to either attach that repo or run this task from
  a session that has it.
- [ ] T013 SC-001: `code.ts` compiled `--target node` drives a stub model
  end to end (`scripts/e2e_full_stack.mjs` against the node build).
  **Not achievable as literally stated, and not by anything left in 508's
  own scope**: read `scripts/e2e_full_stack.mjs` directly — it drives
  `bin/joule --share`, exercising the relay/daemon path, which needs
  `net.createServer` for the relay's own listener. That is spec 508's own
  Decision point 3, refused on this target permanently until a future,
  separate spec gives the language a non-blocking server handler form.
  This is not a gap this round left behind; it is the same boundary 508
  drew from the start. A narrower "drives a stub model" proof — the CLI's
  own non-daemon terminal path, without `--share` — is blocked today only
  by spec 509 (found this round), not by anything unresolved in 508.
- [ ] T014 Gate: `zig build test`, `zig build conformance`,
  `node --test packages/node-runtime/tests/`; `sh tools/codemap.sh`; commit.

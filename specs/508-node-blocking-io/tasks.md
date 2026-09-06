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
- [ ] T005 `net.connect`/`Socket.read()`/`Socket.write()`/`Socket.close()`
  (054): broker owns the real `net.Socket`; mirror the spike's connect/read
  exactly, including the same-synchronous-turn listener rule the spike
  found necessary.
- [ ] T006 `http.request`/`http.stream(...).read()` (042, 452): broker owns
  a `http.request`; response headers and body chunks cross the bridge the
  same way socket reads do.
- [ ] T007 `child_process.spawn(...).readLine()` (450): broker owns the
  child process; line-buffer stdout in the broker (mirroring the native
  `LumenChildProcess` handle) so `readLine()` returns one line per call
  the same way natively.
- [ ] T008 `readline.question` (058): broker-side blocking read of one line
  from stdin's bridged fd (the tty shims from Joule spec 004 T002 already
  solve non-timeout blocking reads on stdin directly, without a broker —
  decide here whether `readline.question` reuses that path instead of the
  broker; it never needs a *timeout*, only a block, so it may not need the
  broker at all).

## Phase 3: Worker.run and the server rejection

- [ ] T009 `Worker.run(fn)` (059): a `worker_threads` Worker running the
  emitted module, `fn` selected by name, scalar-only result via message
  passing — no broker involved, this one already fits Node's own model
  (spec's Decision point 2).
- [ ] T010 `net.createServer`/`http.createServer`: `E_TARGET_UNSUPPORTED`
  naming this spec, per the Decision's point 3. A diagnostics conformance
  case pinning the exact message.

## Phase 4: Conformance and Joule

- [ ] T011 Conformance manifest: `process.sleep(250)` measures >= 250ms
  (SC-002, guarded by T002's fix); a `readLine()` loop over `spawn("cat")`
  round-trips 10k lines without drift; `net.createServer` reports
  `E_TARGET_UNSUPPORTED` (SC-003).
- [ ] T012 Joule spec 004 T003 (`make node`, `make node-test`): with T004–T008
  landed, `code.ts` should clear `providers/openai.ts`'s `http.stream` and
  compile in full. Run it; record what's still unsupported (`node-skip.txt`).
- [ ] T013 SC-001: `code.ts` compiled `--target node` drives a stub model
  end to end (`scripts/e2e_full_stack.mjs` against the node build).
- [ ] T014 Gate: `zig build test`, `zig build conformance`,
  `node --test packages/node-runtime/tests/`; `sh tools/codemap.sh`; commit.

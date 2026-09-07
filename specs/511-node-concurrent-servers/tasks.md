# Tasks: 511 `net.createServer`/`http.createServer` on the node target

**Input**: spec.md's Requirements/Success Criteria, plan.md's Decisions and
Sequencing. Planning only — nothing below is implemented yet. Depends on
508 (broker foundation) and 509 (done — no longer blocks Joule's CLI path;
this is what's left for `--share` specifically).

## Phase 1: Broker protocol — concurrent per-handle I/O

- [x] T001 Spiked (`packages/node-runtime/spike/511-concurrent-handles/`):
  `Atomics.waitAsync` against a per-handle control block resolves N
  independent pending reads without blocking the calling thread's event
  loop or serializing them against each other. `main.mjs` proves all three
  properties at once with two handles (A: 500ms, B: 50ms): (1) a
  main-thread timer armed before both calls fires while both are still
  pending -- `Atomics.waitAsync` genuinely doesn't block; (2) B resolves
  strictly before A -- the two handles run concurrently, not FIFO-
  serialized by submission order; (3) each response carries its own
  handle's tag -- no cross-talk between control blocks. All three: PASS.
  Confirmed even spec 508's own existing broker needs this: its
  `listenLoop()` (`spike/broker.mjs`, promoted as-is into
  `lib/broker/broker.mjs`) only ever has one request in flight per control
  block by construction -- it must fully answer request N before it can
  even look at request N+1 -- regardless of how async its own internal
  socket handling already is.

  Re-derived, not assumed, per the task's own instruction: spec 508's
  `setInterval` keep-alive fix for `Atomics.waitAsync` is needed again
  here, but only on the **broker worker** side (`broker.mjs`'s
  `serviceHandle` loops) -- confirmed by a separate check
  (`keepalive_check.mjs`) that the **calling** (main-thread) side needs no
  such fix: an `await`ed `Atomics.waitAsync` inside an `async function`
  naturally keeps Node's event loop alive on its own (there's a live
  Promise chain the runtime is already tracking), unlike a worker's bare
  `listenLoop()`/`serviceHandle()` with no outer caller referencing it.
  This resolves plan.md's "re-derive rather than assume" note: the fix
  transfers to the broker side unchanged, but does not exist on the
  calling side at all, and `singleton.mjs`'s future `callHandle` (T004)
  needs no analogous keep-alive of its own.
- [x] T002 `protocol.mjs`: added `OP_LISTEN` (args: a port `u32`, reusing
  `encodeHandleArgs`'s exact shape under its own name
  `encodeListenArgs`/`decodeListenArgs`; result: a listener id, reusing
  `encodeConnectResult`). No new wire format needed for the accept
  notification itself (see T003) — `postMessage`'s structured clone carries
  a plain object plus the `SharedArrayBuffer` references directly, no
  binary encoding required, unlike every request/response op.
- [x] T003 `broker.mjs`: `opListen` — a real `net.createServer`, one real
  listener per call. Each accepted connection is registered in the SAME
  `handles` map `opConnect` already uses (`kind: "socket"`, identical
  shape), so `handleOp`'s existing OP_READ/OP_WRITE/OP_CLOSE dispatch
  needed NO changes at all to serve it. What's new: `serviceHandle(handle,
  controlSAB, dataSAB)`, a per-handle counterpart to the existing
  `listenLoop()` — one such loop per accepted connection, each on its own
  control/data pair, all running concurrently on the broker's one thread
  (proven safe by T001's spike). A listen failure (e.g. `EADDRINUSE`) now
  resolves the op with a dead-handle result instead of hanging forever —
  found for real, not hypothetically: `Worker.run` re-executes its whole
  target module's top-level code on the spawned thread (spec 508 T009's
  own documented consequence), so an early test that put `net.createServer`
  and its `Worker.run`-dispatched client in the SAME file called
  `net.createServer` a second time on the worker thread, hit `EADDRINUSE`
  on the already-bound port, and hung the whole conformance case until the
  runner's own timeout — the ORIGINAL `server.on("error", () => {})` did
  nothing, so nothing ever resolved that promise. Fixed here; the
  conformance example itself also now deliberately keeps its listener and
  its `Worker.run` target in separate files (see `examples/valid/`, T013)
  as the correct pattern going forward, not merely a workaround for the
  bug.
- [x] T004 `singleton.mjs`: `callHandle(controlSAB, dataSAB, op, argBytes)`
  — the `Atomics.waitAsync`-based, non-blocking counterpart to `call()`,
  scoped to one handle's own control block, exactly per T001's spike.
  Does not touch `call()` or the process-wide control block (still used by
  `process.sleep`, a bare `net.connect`, `child_process.spawn`, `OP_LISTEN`
  itself). Also added `onAccept(listenerId, onConn)`, routing
  `postMessage`d accept notifications by listener id, and — a real finding,
  not a hypothetical — `onAccept` now `ref()`s the broker worker
  (`start()` `unref()`s it by default): a listener has no bounded wait of
  its own the way every other blocking call's synchronous `Atomics.wait`
  does, so without this a program (or a `Worker.run(listenerFn)` thread,
  Joule's own actual pattern) whose only remaining work is "wait for
  connections" would fall idle and exit the moment its own top-level
  script finished, taking the listener down with it. Confirmed by running
  the T013 conformance case before this fix: it printed nothing and hung.

  **Follow-up fix, found later**: `ensureMessageListener`'s "have I
  attached my one `message` listener yet" check was a module-level
  `messageListenerAttached` boolean, not scoped to which `Worker` it was
  attached to. `shutdownBroker()` (used by several test files' own
  `after()` hooks to recycle the broker between tests) replaces
  `instance` with a fresh `Worker` on the next blocking call, but left
  that flag set — so the next `net.createServer` call after a recycle
  never got a listener attached to the NEW worker at all, and every
  connection it accepted had nowhere to route its accept notification,
  hanging the handler forever. Invisible running `net.test.mjs` alone
  (nothing recycles the broker mid-file); found only by running the
  whole `node --test packages/node-runtime/tests/` suite together, where
  earlier files' own `shutdownBridge()` calls trigger the recycle before
  `net.test.mjs`'s own createServer tests run. Fixed by resetting
  `messageListenerAttached = false` inside `shutdownBroker()`; regression
  test added to `net.test.mjs` ("a second listener still delivers
  connections after shutdownBridge() recycled the broker worker"),
  confirmed to hang without the fix and pass with it.
- [x] T005 New `packages/node-runtime/lib/broker/async_bridge.mjs`:
  `asyncListen`/`onAccept`/`asyncRead`/`asyncWrite`/`asyncClose`, the
  public surface `lib/net.mjs` calls into (mirroring `sync_bridge.mjs`'s
  own role for the synchronous surfaces — nothing outside this file and
  `sync_bridge.mjs` should reach for `singleton.mjs`/`protocol.mjs`
  directly). `sync_bridge.mjs` itself is untouched.
- [x] T006 `node --test`: `tests/net.test.mjs` gained two real tests --
  "a real client round-trips through a real async handler" (basic
  correctness) and "two connections make progress concurrently, one does
  not stall the other" (the actual property this spec exists for: a
  connection that `await`s a read forever must not block a second,
  differently-ported connection on the same listener from being served
  promptly — the second test's whole design is proving that, not just
  smoke-testing that `createServer` doesn't throw). Both pass in single-
  digit milliseconds. `tests/stubs.test.mjs`'s and `tests/net.test.mjs`'s
  own PRE-EXISTING `net.createServer(...)` throw-assertions (written when
  the call was still universally refused) had to be found and fixed too —
  caught by actually running the full `node --test` suite, not by reading
  the diff: with the throw removed, the old assertions' calls started a
  REAL listener that `after()` never shut down, hanging the whole test
  process (the same `ref()`d-worker mechanism T004 added, working exactly
  as designed — just not yet accounted for in those two pre-existing
  tests).

## Phase 2: Language surface — the async handler shape

- [x] T007 `lumen_check_stdlib.zig`: accepts `(socket: Socket) => void`
  (sync) or a named `async function` shaped `(socket: AsyncSocket) =>
  Promise<void>` (`netServerHandlerIsAsync`, checked once against the
  handler's own inferred type — no `ensureAssignable`-sync-then-retry-
  async double-diagnostic risk). Resolved the "does the checker know the
  target" question: it doesn't, and still doesn't — both shapes are
  accepted unconditionally at check time, and each backend's emitter
  refuses what it can't lower (T009's `netServerSyncRefused`, T010's
  native gap), the same pattern as every other node-only construct.
  **A real finding changed the design from the plan**: `AsyncSocket` had
  to become a genuinely distinct `types.Type` (`async_socket_type`,
  `lumen_types.zig`) from `Socket`, not "Socket used inside an async
  function" — tried the simpler context-sensitive idea first, rejected it
  before writing any code: a plain `net.connect()` `Socket` is ALWAYS
  sync-backed at runtime regardless of which function calls it, on both
  targets, so making its TYPE (and therefore whether `.read()` requires
  `await`) depend on "is the enclosing function async" would have silently
  changed the type of existing, unrelated `Socket` usage inside any async
  function anywhere in the codebase. `asyncSocketMethod`
  (`lumen_check_methods.zig`, dispatched via a new `types.isAsyncSocket`)
  mirrors `socketMethod` exactly except every return type is
  `Promise`-wrapped.
- [x] T008 `lumen_emit_js_stdlib.zig`: `net.createServer` removed from
  `unsupportedStaticCall` entirely (handled instead in
  `lumen_emit_js_expr.zig`, before that function is ever consulted for it
  — mirrors `Worker.run`'s own special-casing). A *sync* handler on node
  still refuses, via a new `netServerSyncRefused` (mirrors
  `workerRunShape`'s "name the accepted shape" pattern) naming the
  `async`/`AsyncSocket` form. `http.createServer` stays in
  `unsupportedStaticCall`, its refusal reason updated from "508's Decision"
  to "511 hasn't covered it yet" (T012) — including the shared diagnostic
  call site's hardcoded spec tag (508 → 511), since `http.createServer` is
  the only name left reaching it.
- [x] T009 `lumen_emit_js_expr.zig`: the async-handler call site needed NO
  special codegen at all, simpler than expected and simpler than
  `Worker.run`'s descriptor rewrite — `net.createServer(port, handler)`'s
  existing generic passthrough emission (`namespace.name(args)`, already
  used for every plain stdlib call) already produces exactly the right JS,
  since the handler is an ordinary named function reference staying on the
  same thread, not a value that needs to cross a new one.
- [x] T010 Done properly, not left as the documented gap it started as: the
  checker now knows the compile target. `checkProgram` (`lumen_check.zig`)
  takes a new `target_is_node: bool`, threaded from `lumen_compiler.zig`'s
  `frontEnd` (`options.target == .node` — the one and only caller), stored
  on `Checker.target_is_node`. `netCallType`'s `createServer` handling
  (`lumen_check_stdlib.zig`) refuses an async handler outright when
  `!self.target_is_node`, with a real `E_TARGET_UNSUPPORTED` diagnostic at
  the call site's own line/col naming both what's wrong and what native
  needs instead — resolving plan.md's own open question 1 (whether the
  checker or each emitter enforces target-appropriate shapes) in the
  checker's favor for this construct, since the fix turned out to be small
  (one bool, one field, one call-site update — not the "real, separate
  plumbing work" the original estimate expected). Before this fix,
  compiling the T013 conformance example natively failed at `zig
  build-exe` with a raw "undeclared identifier" error, surfaced through
  Lumen's generic "the native backend rejected this statement's generated
  code... likely a Lumen compiler bug" wrapper — a real failure, not a
  silent miscompile, but actively misleading wording for a documented,
  intentional gap. Now it fails at check time with the proper message.
  `lumen_types.zig`'s `async_socket_type` → `*LumenAsyncSocket_...` name
  is kept as a backstop (should be unreachable now) rather than removed.
  New conformance case: `511.async-handler-native.diagnostics`
  (`examples/invalid/async-handler-native.ts`, `phase: "diagnostics"`,
  `E_TARGET_UNSUPPORTED`).

## Phase 3: `lib/net.mjs`/`lib/http.mjs`

- [x] T011 `net.createServer`: real implementation
  (`packages/node-runtime/lib/net.mjs`) — `asyncListen` + `onAccept`
  (T005), each accepted connection wrapped in a new `AsyncSocket` class
  (mirrors `Socket`, `await`-able instead of blocking, backed by its own
  control block) and dispatched as `Promise.resolve(handler(socket))`,
  deliberately NOT `await`ed by the accept callback itself — awaiting it
  there would serialize every connection behind whichever one is currently
  running, exactly the bug this whole spec exists to fix (documented
  in-line, since it is easy to "fix" back into a bug by adding an
  `await` that looks like an obviously-safe cleanup). A failed listen
  exits the process the same blunt way native's own failed `addr.listen`
  does (`std.process.exit(1)`, `src/lumen_runtime_net.zig`) — no sensible
  degrade-to-dead-handle fallback exists for a server that never bound its
  port.
- [ ] T012 `http.createServer`: not done in this pass — still refused,
  unconditionally, regardless of handler shape. A real, separate follow-up
  (buffered vs. streaming handler forms need their own design pass, not a
  copy-paste of `net.createServer`'s).

## Phase 4: Conformance

- [x] T013 `specs/511-node-concurrent-servers/examples/valid/
  net_create_server.ts` (+ `net_create_server_client.ts`, split
  deliberately — see T003's own note on why) and
  `conformance/manifest.json`'s `511.net-create-server.node`: a real
  listener, a real client connection over loopback, an echo round trip —
  registered in `build.zig` (`conformance_cmd_511`). The STRONGER
  concurrency proof SC-001 describes (client A idle, client B still
  served promptly) lives in `packages/node-runtime/tests/net.test.mjs`
  instead (T006) — a plain-JS runtime test can express and time-bound
  "does connection B get served while A never sends anything" far more
  directly than a `lumen compile`+run conformance case can; the
  `.ts`-level case here proves the LANGUAGE surface (checker + emitter +
  runtime all agree on the async handler shape end to end), not the
  concurrency guarantee specifically. Both together cover SC-001.
- [x] T014 Updated `specs/508-node-blocking-io/conformance/manifest.json`'s
  `508.unsupported.net-create-server`/`.http-create-server` and
  `specs/504-node-target-emitter/conformance/manifest.json`'s
  `node.unsupported.net-server` (SC-003), including their source fixtures'
  own comments (which had explicitly claimed a permanent, unconditional
  refusal — now false) and line numbers (the comment-length edits moved
  the call site).

## Phase 5: Joule adoption (joule-sh/code, spec 004 — not this repo)

- [ ] T015 Rewrite `src/relay/ws.ts`'s two `net.createServer` handlers to
  the async shape, `await`ing every `Socket.read()`/`.write()` reached
  through the call chain (`src/relay/http_transport.ts`'s `socketHandler`,
  `src/vendor/websocket/server.ts`'s `handleConnection`, and anything else
  blocking in that path).
- [ ] T016 SC-002: `scripts/e2e_full_stack.mjs --share` end-to-end on the
  node target, with two real concurrent client connections (not one) —
  the actual acceptance bar this whole spec exists for.
- [ ] T017 Separately, unrelated to `createServer` but found while reading
  this code for this plan: `ws.ts`'s `Worker.run(() => { return
  pusherLoop(peer, logPath, since, false); })` captures `peer` (non-scalar)
  and already fails Node's `Worker.run` today regardless of this spec.
  Needs its own fix (likely: refactor `pusherLoop` to take a handle/id
  instead of a `Peer` object, or extend `Worker.run`'s accepted capture
  types) — filed here so it isn't mistaken for something Phase 1-4 already
  resolves; not blocking `net.createServer` itself.

## Phase 6: Gate

- [ ] T018 `zig build test`, `zig build conformance`, `node --test
  packages/node-runtime/tests/`; `sh tools/codemap.sh`; commit.

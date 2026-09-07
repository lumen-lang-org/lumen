# Tasks: 511 `net.createServer`/`http.createServer` on the node target

**Input**: spec.md's Requirements/Success Criteria, plan.md's Decisions and
Sequencing. Planning only — nothing below is implemented yet. Depends on
508 (broker foundation) and 509 (done — no longer blocks Joule's CLI path;
this is what's left for `--share` specifically).

## Phase 1: Broker protocol — concurrent per-handle I/O

- [ ] T001 Spike first, promote like 508 did: prove `Atomics.waitAsync`
  against a per-handle control block resolves N independent pending reads
  without blocking the calling thread's event loop or serializing them
  against each other (a timer armed before two concurrent reads must fire
  while both are still pending). Re-derive the event-loop keep-alive fix
  spec 508's own spike needed for `Atomics.waitAsync` (an inert
  `setInterval`) rather than assuming it transfers unchanged to a
  different thread/direction.
- [ ] T002 `protocol.mjs`: wire format for allocating/freeing a per-handle
  control block (plan.md decision 2) and for the accept-notification op
  `net.createServer`'s broker-side listener uses to hand a new connection's
  handle back to whichever thread is awaiting it (plan.md decision 3).
- [ ] T003 `broker.mjs`: real `net.createServer`/`http.createServer`
  registration and accept loop (today refused before ever reaching the
  broker); a live per-connection handle table alongside the existing
  socket/http-stream/child-process ones (T005-T007 of spec 508); allocate
  a fresh per-handle control block at accept time, free at close.
- [ ] T004 `singleton.mjs`: `callHandle(handle, op, argBytes)` — the
  `Atomics.waitAsync`-based, non-blocking counterpart to `call()`, scoped
  to one handle's own control block. Does not touch or replace `call()`
  and the existing process-wide control block (still used by
  `process.sleep`, a bare `net.connect`, `child_process.spawn`, etc.).
- [ ] T005 New `async_bridge.mjs` (or similarly named module, sibling to
  `sync_bridge.mjs`): `asyncRead`/`asyncWrite`/`asyncClose`/etc. returning
  real `Promise`s, built on `callHandle`. `sync_bridge.mjs` itself is
  unchanged — this is additive, for use only from inside a server handler.
- [ ] T006 `node --test`: broker-level tests proving T001's concurrency
  property survives the real module boundaries (not just the spike),
  matching the depth of `packages/node-runtime/tests/broker.test.mjs`'s
  existing coverage.

## Phase 2: Language surface — the async handler shape

- [ ] T007 `lumen_check_stdlib.zig`: accept an `async (socket: Socket) =>
  Promise<void>` handler shape for `net.createServer` (mirror for
  `http.createServer`'s buffered/streaming forms) alongside the existing
  sync one — decide during implementation whether the checker enforces the
  target-appropriate shape itself (needs the target threaded through, which
  it doesn't have today) or accepts both and lets each emitter refuse what
  it can't lower (plan.md T002's open call, matching how every other
  node-only restriction already works via `E_TARGET_UNSUPPORTED` at emit
  time).
- [ ] T008 `lumen_emit_js_stdlib.zig`: remove `net.createServer`/
  `http.createServer` from `unsupportedStaticCall` (same move spec 508
  T009 made for `Worker.run`). A *sync* handler on node stays refused —
  new clear diagnostic naming the accepted async shape (mirror
  `workerRunShape`'s pattern: name what's accepted, not just what's
  missing).
- [ ] T009 `lumen_emit_js.zig` / `lumen_emit_js_expr.zig`: codegen for the
  async-handler call site. Expected to be simpler than `Worker.run`'s
  descriptor rewrite (spec 508 T009) since the handler stays ordinary
  emitted JS on the same thread — likely close to a direct passthrough
  into `lib/net.mjs`'s new `createServer`.
- [ ] T010 Native emitter (`lumen_emit_static.zig`): confirm the sync-only
  path is genuinely untouched (plan.md decision 1 — native stays sync-only
  for this spec) and that a program using the new async handler shape
  fails cleanly on native with a real diagnostic if T007 accepts the shape
  unconditionally at check time, rather than silently miscompiling.

## Phase 3: `lib/net.mjs`/`lib/http.mjs`

- [ ] T011 `net.createServer`: real implementation routed through the
  broker (plan.md decision 3) — accepted connections dispatched as `await
  handler(socket)`, running concurrently across connections via ordinary
  event-loop concurrency, no `worker_threads.Worker` per connection.
- [ ] T012 `http.createServer`: same shape for both the buffered
  (`(req) => HttpResponse`) and streaming (`(req, res) => void`) handler
  forms spec 042/452 already established for the native/sync semantics —
  decide whether both need the async treatment or only the streaming one
  realistically holds a connection open long enough to matter.

## Phase 4: Conformance

- [ ] T013 SC-001's litmus-test case: client A connects and holds the
  connection open without sending anything further; client B connects,
  sends a request, and gets a timely response despite A's connection
  sitting idle on the same listener. This is the case that actually proves
  the feature — a version that only ever gets exercised by one connection
  at a time is not done, however clean the rest of the suite looks.
- [ ] T014 Update `specs/508-node-blocking-io/conformance/manifest.json`'s
  `508.unsupported.net-create-server`/`.http-create-server` and
  `specs/504-node-target-emitter/conformance/manifest.json`'s
  `node.unsupported.net-server` (SC-003): pin the new boundary (sync
  handler refused by name; async handler compiles and runs) instead of the
  old blanket refusal these currently check.

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

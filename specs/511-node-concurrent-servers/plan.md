# Plan: 511 `net.createServer`/`http.createServer` on the node target

**Input**: spec.md's Problem, Requirements, and Open Questions. This plan
resolves the open questions provisionally (pick a default, mark it
reversible) so `tasks.md` has something concrete to implement; a review
before implementation starts can override any of these defaults without
reshaping the rest.

## Decisions (defaults for the open questions in spec.md)

1. **Native stays sync-only for now.** Adding a non-blocking I/O primitive to
   the Zig runtime is a separate, materially larger undertaking (no existing
   piece to extend the way spec 508's broker extended to node) and nothing
   in Joule's own code needs it natively — native's thread pool already
   gives it real concurrency. Revisit only if a concrete native need shows
   up.
2. **Broker protocol: a control block per live handle, not a shared pending-
   request table.** `OP_CONNECT`/`OP_HTTP_STREAM_OPEN` (and the new
   accept-driven handle creation this spec adds) already mint a numeric
   handle per live connection; give each one its own small
   `SharedArrayBuffer` pair (`control`, `data`) at creation, freed at close.
   Simpler than a multiplexed single-block protocol (no request-ID routing
   table, no risk of one handle's slow response starving another's), at the
   cost of one broker-side registration per handle instead of one global
   one. `singleton.mjs`'s existing single control block stays exactly as it
   is for the calling thread's *own* blocking ops (`process.sleep`, a plain
   `net.connect` outside a handler, `child_process.spawn`) — this is
   additive, not a rewrite of the existing path.
3. **`net.createServer`/`http.createServer` accept on the broker worker,
   not the calling thread.** Consistent with `Socket`/`http.stream` already
   living behind the broker (spec 508 T005/T006), and keeps exactly one
   real Node `net`/`http` server instance total per program regardless of
   how many Lumen threads call `createServer` (matters once Joule's
   pattern — `Worker.run(listenerFn)` — puts the `createServer` call
   itself on its own worker thread; the broker is process-wide, so this
   composes without a second server-per-thread problem to solve). The
   accepted-connection notification and all subsequent read/write for that
   connection cross the calling thread's per-handle control block from
   decision 2.

## Where the reference behavior lives (native, per surface)

- `src/lumen_runtime_net.zig` (~line 379 on): `http.createServer`'s request-
  line/header parsing, keep-alive loop, and (`needs_http_threadpool`) the
  `libxev.ThreadPool` dispatch. `net.createServer`'s equivalent pool is the
  same mechanism, spec 490 per the file's own comments.
- `src/lumen_check_stdlib.zig` ~728 (`http.createServer`) and ~844
  (`net.createServer`): today's handler-shape validation — sync-only. This
  is the checker code FR-001 extends to accept an async handler shape on a
  per-target basis (the checker doesn't know the target at check time
  today; see Task T002).
- `src/lumen_emit_static.zig` ~890/~904: the *native* emitter's codegen for
  these calls — unaffected by this spec, included here only so a future
  reader doesn't confuse it with the node emitter work.

## Where spec 508's broker work applies

- `packages/node-runtime/lib/broker/protocol.mjs`: wire format — op codes,
  control-word layout (`ARG_LEN`/`OP`/`REQ_ID`/`STATE`/`RESP_STATUS`/
  `RESP_LEN`), argument/result encoders. Extend with: a new op for
  "register a per-handle control block" (or fold it into the existing
  accept/connect/stream-open response, returning the new block's identity
  alongside the handle), and async variants of the read/write encoders
  (likely identical wire shape to the sync ones — only the calling
  convention on the JS side changes).
- `packages/node-runtime/lib/broker/broker.mjs`: the worker-side op
  dispatch and the real Node `net`/`http` calls underneath. Needs: a real
  `net.createServer`/`http.createServer` call (today refused before ever
  reaching here — `lib/net.mjs`/`lib/http.mjs` throw by name without a
  broker round trip at all), a live per-connection handle table (mirroring
  the existing socket/http-stream/child-process handle table T005-T007
  built), and, per decision 2, allocation of a fresh per-handle control
  block at accept time, torn down at close.
- `packages/node-runtime/lib/broker/singleton.mjs`: `call()` stays as the
  single-outstanding-request path for the process-wide control block
  (`process.sleep` and friends). New: a per-handle variant — call it
  `callHandle(handle, op, argBytes)` — that looks up (or lazily requests)
  that handle's own control block and does the same `Atomics.store`/
  `Atomics.notify` dance on it, but is only ever awaited from an `async`
  context, so it must NOT `Atomics.wait` on the calling (main-ish) thread;
  see Task T001 for how the async wait actually resolves without blocking
  the event loop that has to run it.
- `packages/node-runtime/lib/broker/sync_bridge.mjs`: the existing
  `sync*` functions stay as they are (used outside handlers). New file or
  section, e.g. `async_bridge.mjs`, with `asyncRead`/`asyncWrite`/etc.
  returning real `Promise`s, built on `callHandle`.

## The actual hard part: awaiting a `SharedArrayBuffer` handshake without blocking

`Atomics.wait` is synchronous by construction — it is what spec 508 uses
*because* it blocks. An async, non-blocking wait on the same
`Int32Array`/`STATE` word needs `Atomics.waitAsync` (already used once in
this codebase's history — spec 508's spike found "`Atomics.waitAsync`'s
promise doesn't keep a worker's event loop alive" and fixed it with an
inert `setInterval` keep-alive; that fix lived in the *broker worker*, for
its own long-running loop — the same shape of problem will recur here, but
now on the *calling* thread waiting for a per-handle response, so re-derive
rather than assume the old fix transfers unchanged). `callHandle` becomes,
roughly: post the request the same way `call()` does, then `return
Atomics.waitAsync(controlBlock, P.STATE, P.REQUEST_POSTED).value.then(() =>
{ ...read the response... })`. Because each handle has its OWN control
block (decision 2), N connections' pending reads each get their own
independent `Atomics.waitAsync` promise — no shared-state serialization
between them, no request-ID demultiplexing needed.

## Sequencing

1. **T001 — broker protocol: per-handle control blocks + async wait.**
   Prove this in isolation first, the same way spec 508 proved the
   original broker design with a spike before promoting it
   (`packages/node-runtime/spike/`, kept as historical reference): two
   handles, two outstanding reads, confirm both resolve independently and
   neither blocks the other or the calling thread's event loop (a timer
   armed before both reads must fire while they're pending — same style of
   proof spec 508 T009's own worker concurrency test used).
2. **T002 — checker: accept an async `createServer` handler shape.**
   Extend `lumen_check_stdlib.zig`'s validation. The checker doesn't
   currently know the compile target; either thread the target through
   (as `lumen_emit_js.zig`'s refusal-by-name pattern does at emit time
   instead of check time — likely the simpler option, matching how
   `Worker.run`'s shape constraints are enforced at emission, not
   checking) or accept both shapes unconditionally at check time and let
   each backend's emitter refuse what it can't lower, exactly as
   `E_TARGET_UNSUPPORTED` already works for every other node-only
   restriction.
3. **T003 — node emitter: codegen for the async-handler `createServer`
   call.** `lumen_emit_js_stdlib.zig` (remove from `unsupportedStaticCall`,
   same move as `Worker.run` in spec 508 T009), `lumen_emit_js.zig`/
   `lumen_emit_js_expr.zig` (the actual call-site lowering — likely a
   direct `net.createServer(port, handler)` passthrough into
   `lib/net.mjs`, given the handler is already ordinary emitted JS by this
   point, unlike `Worker.run`'s descriptor rewrite). A *sync* handler stays
   refused with a clear message naming the accepted async shape (mirror
   `workerRunShape`).
4. **T004 — `lib/net.mjs`/`lib/http.mjs`: real `createServer`.** Wire the
   accept-and-dispatch through the broker (decision 3), each accepted
   connection getting a live handle + control block (T001), the Lumen
   handler invoked as `await handler(socket)` per connection, running
   concurrently across connections via ordinary Node/broker event-loop
   concurrency — no `worker_threads.Worker` per connection.
5. **T005 — conformance.** SC-001's two-client litmus-test case (both
   targets where applicable — native's existing sync path already passes
   this trivially via its thread pool; the node case is the one actually
   proving something new). Update `508.unsupported.net-create-server`/
   `.http-create-server` and `node.unsupported.net-server` (specs 504/508)
   to pin the new boundary (SC-003) instead of the old blanket refusal.
6. **T006 — Joule adoption (joule-sh/code, spec 004, not this repo).**
   Rewrite `src/relay/ws.ts`'s two `net.createServer` handlers (and
   `src/relay/http_transport.ts`'s `socketHandler`, and
   `src/vendor/websocket/server.ts`'s `handleConnection`, and anything else
   in the call chain that does blocking reads/writes) to the `async` shape,
   `await`ing every `Socket.read()`/`.write()`. Verify `--share` end-to-end
   on node via `scripts/e2e_full_stack.mjs` (spec 508's own T013, SC-001)
   with two real concurrent client connections, not one.

## Verification

- `zig build test` and the new/updated `zig build conformance` cases
  (T005) after T001-T004.
- `node --test packages/node-runtime/tests/` for the new broker/net tests
  (T001, T004).
- The concurrency litmus test (SC-001) is the one that actually matters
  here — a version of this feature that compiles and runs with exactly one
  connected client but silently serializes a second is not done, however
  green the rest of the suite is.
- Joule's own `make node`/`make node-test` (spec 004 T003, still blocked on
  T006 landing there) and `scripts/e2e_full_stack.mjs --share` end-to-end
  (SC-002) are the real acceptance bar for this spec's stated purpose —
  green conformance here is necessary, not sufficient, until those pass
  too.

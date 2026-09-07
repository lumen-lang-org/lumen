# Spec 511: `net.createServer`/`http.createServer` on the node target

**Status**: Draft (plan only, not scheduled) | **Parent**: 508 | **Blocks**: Joule's
`--share` (spec 004) on the node target

## Problem

Spec 508 refused `net.createServer`/`http.createServer` on the node target
permanently, `E_TARGET_UNSUPPORTED`, reasoning that "Node's per-thread isolate
model can't give a per-connection handler shared module state without a new
`async` handler form the language doesn't have yet." That refusal is why
`joule --share` — the daemon/relay path, the one thing spec 509's fix didn't
unblock — still cannot run on this target: `src/relay/relay.ts` and
`src/relay/ws.ts` (joule-sh/code) call `net.createServer` directly.

This spec plans the fix. It does not implement it.

## What's confirmed, so the design starts from the real shape of the problem

Read directly, not assumed:

- **Native's own concurrency model** (`src/lumen_runtime_net.zig`, spec 049):
  each accepted connection's entire handling is handed to a worker thread
  from a real OS thread pool (`libxev.ThreadPool`); `accept()` loops back
  immediately. The code's own comment is explicit about the cost: "the
  handler now genuinely runs on multiple OS threads concurrently. If a
  handler mutates shared global state, that's now a real data race... Not
  addressed here (would need a general-purpose locking primitive Lumen
  doesn't have yet)." **Native does not actually give a handler safe shared
  mutable module state either** — it hands out real concurrency and leaves
  safety to the handler's own discipline. The bar for a Node design is not
  "match native's safety guarantees" (native has none beyond documentation);
  it's "match native's concurrency" without native's cost model, which does
  not transfer (see below).
- **Joule's actual handlers don't need shared mutable state.** Read
  `src/relay/relay.ts` and `src/relay/ws.ts` (joule-sh/code) directly:
  - All three listeners (`runHttpListener`, `runTerminalWsListener`,
    `runBrowserWsListener`) already run via `Worker.run(listenerFn)` — a
    plain top-level function, the one shape spec 508 T009 already supports
    on Node. `net.createServer` itself is only ever called from *inside*
    one of those, i.e. from a thread that already has its own full copy of
    the module's top-level state (a Node worker re-runs the target module's
    top-level code, spec 508 T009's `worker_bootstrap.mjs`). So the
    handler value passed to `net.createServer` (`socketHandler(...)` /
    an inline arrow) is built from that thread's *own* top-level
    functions/exports — nothing needs to cross a *new* thread boundary for
    `createServer` to call it.
  - Cross-connection and cross-listener coordination goes through
    `callStore`/`remoteStoreCaller` — an RPC to a separate `RelayOwner`
    running on the main thread — not through shared in-process mutable
    state. Each connection gets its own local `ConnState`. This is
    precisely the discipline native's own doc comment says a handler needs
    to keep itself safe; Joule already keeps it.
  - One unrelated gap found in passing, out of this spec's scope: `ws.ts`
    calls `Worker.run(() => { return pusherLoop(peer, logPath, since,
    false); })`, capturing `peer` (a `Peer` object) — not a scalar, so this
    already fails Node's `Worker.run` today (`E_TARGET_UNSUPPORTED`)
    independent of `createServer`. Not fixed here; noted so it isn't
    mistaken for something this spec's work resolves.
  - **So "shared module state across threads" is not actually the blocking
    problem for Joule's real code.** The blocking problem is narrower and
    different (next point).
- **The real gap is concurrent connections on one thread**, and it is a
  genuine gap, matching spec 508's own instinct that a new `async` handler
  form is needed:
  - Spec 508's blocking-I/O bridge (`packages/node-runtime/lib/broker/`) is
    fundamentally *serial per calling thread*: one `SharedArrayBuffer`
    control block, one outstanding request at a time, `Atomics.wait`-based
    (`singleton.mjs`'s `call()`). A `Socket.read()` that blocks waiting for
    more client bytes halts *that thread's entire event loop* — nothing
    else on it runs, including any other connection's I/O.
  - For one connection at a time that's exactly what spec 508 needed
    (`process.sleep`, one `net.connect`, etc.) and built correctly. It does
    not extend to a server: `ws.ts`'s terminal/browser WebSocket listeners
    need to hold many concurrent, long-lived connections open on the same
    listener thread, each idling on its own read between messages — one
    slow or idle client cannot be allowed to stall every other client on
    the same listener.
  - Native's answer — one real OS thread per connection — does not port:
    a `worker_threads.Worker` is a whole new V8 isolate plus a full
    re-execution of the target module's top-level code (spec 508 T009's own
    design). Spinning one up per accepted TCP connection is not a rounding
    error the way a pooled OS thread is; it is real, per-connection
    startup latency and memory that a relay serving many concurrent
    terminal/browser sessions cannot absorb.
  - Node's actual strength is the opposite shape: one thread, non-blocking,
    event-loop concurrency — which is exactly what plain Node `net`/`http`
    already do, and exactly what Lumen's own `async`/`await` already
    compiles to on this target (confirmed: `lumen_emit_js_stmt.zig` emits
    real `async function`, `lumen_emit_js_expr.zig`'s `.await_expr` emits
    real `await` — spec 505/508's JS is not a simulation of async, it *is*
    JS async). The missing piece is a non-blocking, `await`-able path from
    a Lumen `Socket`/HTTP-stream read/write down to the broker, and a
    server-handler form that uses it.
  - That path does not exist yet at the broker-protocol level either: the
    control block has room for exactly one outstanding request
    (`REQ_ID`/`STATE`/`RESP_*` are singular fields, not a table). Making the
    *JS-facing* API return a `Promise` instead of blocking is necessary but
    not sufficient — two connections on the same listener thread would
    still serialize through the one-request-at-a-time control block even
    if neither one blocks the thread while waiting. The protocol itself
    needs to support multiple concurrently outstanding requests.

## Requirements (draft — refine during planning review, not implementation)

- **FR-001**: `net.createServer`/`http.createServer` accept an `async`
  handler on the node target: `net.createServer(port, async (socket:
  Socket) => { ... })`. A *sync* handler on node stays refused
  (`E_TARGET_UNSUPPORTED`, naming this spec and the accepted shape — same
  pattern as `Worker.run`'s `workerRunShape`), at least for this spec's
  scope; native keeps its existing sync, thread-pooled handler unchanged.
- **FR-002**: Inside an async handler, `Socket`/HTTP-stream reads and
  writes are genuinely non-blocking on node — `await`ing one connection's
  read must let the event loop run other connections' handlers, timers, and
  I/O in the meantime.
- **FR-003**: The broker protocol supports multiple concurrently
  outstanding requests from one calling thread, each resolved independently
  as its response arrives, not serialized through a single-slot control
  block.
- **FR-004**: A handler that never intentionally shares mutable state across
  connections (Joule's own `ConnState`-per-connection, RPC-to-owner pattern)
  needs no new language feature beyond the `async` handler shape itself —
  this spec does not add locking, actors, or any shared-state primitive.
  That mirrors native's own documented position, not a regression from it.

## Open questions this plan does not resolve (flag for the review this spec
## itself asks for, before implementation starts)

- Does native ever get an `async` handler option too (one source works
  identically on both targets), or does native stay sync-only and Node
  become async-only, meaning `net.createServer` call sites become one of
  the (small, growing) family of constructs whose *shape* differs by target
  the way `Worker.run`'s two accepted forms already do? Given native's
  concurrency story is already "real OS threads, handler's problem to stay
  safe," adding `async` there is a materially bigger, separate undertaking
  (the Zig runtime has no non-blocking I/O primitive to await today) and
  should not block this spec.
- Broker protocol shape for FR-003: a control block per live handle
  (allocated at connect/accept/stream-open, freed at close — simpler,
  scales with concurrent connections rather than a fixed pool) vs. one
  control block with a real pending-request table keyed by the existing
  `REQ_ID` field (more general, more work, matches how a normal async RPC
  client is built). Leaning towards per-handle control blocks as the
  narrower first cut; not decided here.
- Whether `net.createServer`'s Node implementation should still route
  through the broker worker at all (for one consistent code path with
  `Socket`/`http.stream`), or accept connections directly on the calling
  thread via plain Node `net.createServer`/`http.createServer` and only use
  the broker for the handler's own further I/O. The second avoids an extra
  cross-thread hop for every accepted connection and matches how plain Node
  servers actually work; needs a decision before Phase 3/4 in `tasks.md`.

## Success criteria (once scheduled)

- **SC-001**: A new conformance case proves real concurrency, not just "it
  runs with one client": client A connects and holds its connection open
  without sending anything further; client B then connects, sends a
  request, and gets a timely response despite A's connection sitting idle
  on the same listener. This is the litmus test that distinguishes genuine
  async concurrency from something that merely compiles and works for a
  single connection.
- **SC-002**: `joule --share` (joule-sh/code, spec 004) runs end-to-end on
  the node target via `scripts/e2e_full_stack.mjs` — spec 508's own T013,
  blocked on exactly this refusal, becomes achievable. Requires
  `src/relay/ws.ts`'s handlers to be rewritten to the `async` shape as
  Joule-side follow-up work (spec 004), not something this compiler spec
  does on Joule's behalf.
- **SC-003**: `508.unsupported.net-create-server`/`.http-create-server` and
  `node.unsupported.net-server` (specs 504/508's own diagnostics cases,
  which pin the *old*, universal refusal) are updated to pin the *new*
  boundary: a sync handler is still refused by name; an async one compiles.

# 492 — Map/Set safety across server thread pools (fixes #12)

## Problem

lumen#12 reported a `Map` shared with an `http.createServer` handler
segfaulting inside `Map.get`'s internal `eqlBytes`, and a follow-up comment
reproduced the same failure family through `net.createServer` once lumen#11
gave it a thread pool too: silent lost updates under light concurrent load,
a hard crash under heavy load.

Reproducing both evidence threads and reading the codegen they go through
(`LumenMap`/`LumenSet` in `src/lumen_compiler.zig`, and the connection
handlers in `src/lumen_runtime_net.zig`) turned up two separate bugs, not
one. Both were filed as the same issue because both surface as the same
`eqlBytes` segfault or a silently wrong count, and both only show up once a
Map or Set outlives the request that fed it.

### Bug 1 — a dangling key, not a race

`http.createServer`'s `HttpRequest.path`/`.method`/`.body`/header strings
are sliced out of that connection's own arena (`carena` in
`__httpCreateServer`'s generated code), reset between keep-alive requests
and freed when the handler returns — deliberately, so a long-running
server's memory does not grow with every request it has ever served (see
the comment above `conn_arena` in `src/lumen_runtime_net.zig`).
`LumenMap.set`/`LumenSet.add` stored a key or value of type `[]const u8`
exactly as received: pointer and length, no copy. A key built from
`req.path` and stored in a module-level `Map` — the original issue's own
repro — is a dangling pointer the instant its connection's handler returns.

This needs no second thread. Confirmed two ways:

- `specs/492-map-set-thread-safety/examples/manual/http-request-scoped-key.ts`,
  driven by eight fully sequential `curl` calls (one at a time, previous
  response received in full before the next connection even opens), crashes
  on request 2 on the unpatched compiler exactly like the issue's own
  report ("one request succeeds; the very next one segfaults"). No two
  requests are ever in flight together.
- The identical program with the key changed from `req.path` to a constant
  string survives twenty sequential requests with no crash, on the same
  unpatched compiler. The only variable changed is where the key's bytes
  live, which isolates the bug to storage lifetime, not access ordering.

`net.createServer` does not have this problem: `LumenSocket.read()` already
copies into the runtime's persistent arena for an unrelated reason (buffer
reuse across reads — see its own comment), so a key built from `socket
.read()`'s output was never dangling.

### Bug 2 — a genuine data race, once the key is fixed

Separately, `LumenMap`/`LumenSet` are one growable-array backing store per
instance (`keys_`/`values_`, or `items_`) with no synchronization of their
own. `http.createServer` (spec 049) and `net.createServer` (spec 490) both
hand each connection to a real OS thread from a `xev.ThreadPool`. An
instance reachable from more than one handler — the ordinary way to keep
state across requests, since there is no per-server context object — can
have two threads append or resize the same backing array at once: a plain
data race on the storage itself, independent of bug 1 and still live once
it is fixed. This is what
`specs/492-map-set-thread-safety/examples/manual/net-store-concurrent-map.ts`
demonstrates, since `net.createServer` was never exposed to bug 1.

This was already a known, documented trade-off (see the comment above
`__httpCreateServer`'s definition — "a real data race... not addressed
here") and spec 468 scoped it out explicitly ("a handler that mutates a
module-level Map is racing, and that is the program's own bug"). It is a
correctness bug in every threaded program that shares a Map or Set this
way, not a hypothetical.

## The design decision

Three shapes were on the table for bug 2 (bug 1 has one honest answer —
copy the value on insert, which is what any language's "the container owns
what you put in it" contract already promises, and it does not trade away
anything the `conn_arena` design was protecting):

1. **Lock inside Map/Set.** Correct for concurrent use of one instance, but
   taxes every single-threaded program with an uncontended acquire/release
   on every op, and does not generalize: `net-store-concurrent-map.ts`'s
   plain `totalOps` field races identically and a Map-level lock does
   nothing for it. Fixing the container does not fix the pattern.
2. **Make the unsafe case loud.** Detect an overlapping access and fail
   immediately and specifically, instead of continuing on corrupted state
   or segfaulting somewhere unrelated.
3. **Document and provide a safe alternative.** Says handlers get no shared
   mutable state and points at a channel or an explicitly synchronized
   container — but Lumen does not have either primitive yet, so this is a
   roadmap item, not something this PR can ship.

This PR takes option 2, narrowly: each `Map`/`Set` instance carries one
atomic flag, checked on every read and swapped on every write, and panics
with a message naming the exact problem and this issue on a detected
overlap — the same trade-off Go's builtin map makes for the identical
problem (Go's own docs: concurrent map writes are a "fatal error", not
memory corruption). Cheap on the uncontended path (a load, or a swap for
writes; see Verified below for the measurement), and a best-effort
detector rather than a guarantee: it does not claim to catch every
interleaving, only to turn the common case of "two threads touched this at
once" into an immediate, addressable error instead of a wrong answer or a
crash inside unrelated code.

**What this does not do.** It does not make it safe to share a Map across
`net.createServer`/`http.createServer` handlers — it makes the fact that
it is unsafe impossible to miss. A handler pattern that relies on
concurrent access to a shared Map (a session store, a rate limiter — see
"Downstream" below) will now fail fast and loudly under real concurrent
load rather than drift into wrong answers. That is a real behavior change
for any program already doing this, and it is the point: the alternative
was shipping wrong answers with nobody knowing. Closing the gap for real —
so a session store can be built without hitting this at all — needs a
supported concurrency-safe container or a message-passing alternative,
which is a design decision for the maintainers, not a compiler patch.

## Change

`src/lumen_compiler.zig`:

- `__lumenOwn(comptime T, v: T) T`: returns `__sa().dupe(u8, v)` when
  `T == []const u8`, `v` unchanged otherwise. Comptime-branched on `T`, so
  a non-string `Map`/`Set` pays nothing — the branch does not exist in the
  generated code for those instantiations. `LumenMap.set` and
  `LumenSet.add` now route the key (and, for `Map`, the value) through it
  before storing.
- `__lumenRaceCheck`/`__lumenRaceBeginWrite`/`__lumenRaceEndWrite`/
  `__lumenConcurrentAccessPanic`: the atomic guard described above. Every
  `LumenMap`/`LumenSet` instance gets one `__writing: std.atomic.Value(bool)`
  field. Read ops (`get`, `has`, `size`, `keys`, `values`, `forEach`) call
  `__lumenRaceCheck`; write ops (`set`/`add`, `delete`, `clear`) bracket
  their body with `__lumenRaceBeginWrite`/`defer __lumenRaceEndWrite`.

No change to `LumenSocket.read()` (already copies into `__sa()`) or to
`__httpCreateServer`/`__netCreateServer`'s connection handling.

## Verified

- `specs/492-map-set-thread-safety/examples/manual/http-request-scoped-key.ts`:
  eight sequential `curl` requests, no concurrency. Unpatched: segfaults on
  request 2, matching the issue's own report exactly. Patched: `1` through
  `8`, one per line, no crash.
- The same file with the key swapped for a constant string, unpatched
  compiler: eight sequential requests survive with no crash — isolates the
  bug to key storage lifetime rather than thread-pool scheduling.
- `specs/492-map-set-thread-safety/examples/manual/net-store-concurrent-map.ts`,
  light load (10 connections × 3000 ops): unpatched loses updates silently
  (`own=` short of 3000, no error printed); patched either completes with
  every `own=3000`, or stops immediately with the guard's runtime error
  naming the exact source line.
- Same file, heavy load (20 connections × 3000 ops, repeated): unpatched
  crashes with `index out of bounds` inside `__find`/`eqlBytes` in roughly
  1 run in 4 (confirmed over 15 repeated fresh runs); patched fails the
  same way every time, with the guard's message instead of a
  segfault-adjacent index panic.
- `specs/492-map-set-thread-safety/examples/valid/single-thread-unchanged.ts`
  (added to the conformance suite): `Map`/`Set` get/set/has/delete/size/
  forEach and add/has/delete/size, output unchanged from before this PR.
  Single-threaded behavior and output are bit-for-bit identical; the guard
  only ever sees itself.
- Single-threaded throughput: a 60,000-op `Map`/`Set` microbenchmark
  (500 distinct keys, repeated get+set / add+has), `--release-fast`,
  5 runs each: baseline 53–55ms (Map) / 32–33ms (Set); patched 53–55ms /
  32–33ms. No measurable difference — the guard is an uncontended atomic
  load or swap per op, and the string copy only fires for `[]const u8`
  instantiations (this benchmark exercises exactly that case and still
  shows no regression, since one `dupe` per unique key is a one-time cost
  the linear `__find` scan already dwarfs).
- `zig build test`: passes.
- `zig build conformance`, patched vs. a fresh baseline built from the same
  base commit (`425a5acfa7d6aefec81cb986c7cb9d68f0fea655`): both trees pass
  302/322 cases with the identical 20 pre-existing failing case names
  (sorted `FAIL` lists diff empty) -- no new failures, no fewer.
- Downstream: `joule-sh/code` (copied, not modified) built against the
  patched compiler with `LUMEN_NO_LOCAL=1`; `make test` — 1112 passed, 0
  failed, including `SessionStore` and `RateLimiter`'s own `Map` fields
  exercised by the relay's test suite.

## Not fixed here

- **Plain scalar or aggregate fields on a shared class instance.** The
  `totalOps` counter in `net-store-concurrent-map.ts` is a plain `int`
  field on the same shared `Store` instance as `counts`, and it loses
  updates under exactly the same concurrent access — the guard is a
  property of `Map`/`Set`'s own generated methods, not of arbitrary field
  reads and writes, and there is no general mechanism in Lumen today to
  detect or prevent that. This is the concrete shape of the "design
  decision" this issue asks for: whether Lumen ever gets a general
  synchronization primitive, a compile-time capture check (there is
  escape analysis for stack-vs-heap placement in `src/lumen_escape.zig`
  already, but it answers a different question — whether an instance
  outlives its own function, not whether two threads can reach it — a
  capture-across-thread-boundary check would be new analysis, not an
  extension of it), or a documented "handlers get no shared mutable state,
  here is the supported alternative" answer. Any of the three is a real
  design commitment; this PR does not make it.
- `LumenEventEmitter`'s internal `StringHashMapUnmanaged` has the same
  unguarded-growable-storage shape as bug 2 and is not touched here — it
  was not part of the reported issue and deserves its own look rather than
  a drive-by change bundled into this one.

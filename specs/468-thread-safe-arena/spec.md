# Feature Specification: Per-Thread Runtime State

## Problem

An HTTP server built with `http.createServer` hands each connection to a worker
thread. Every generated program also carries a handful of process-global
variables that the runtime writes on every function call and every `throw`:
where execution is, whether an error is in flight, what its message was, and
how deep the call stack has got. One set of those, shared by every thread.

So two handlers running at once write over each other's control flow. This is a
correctness bug in every threaded program, not a performance note, and it needs
no unusual code to hit — a handler that calls a function is enough.

From the outside it looks like this. A handler that catches an error and turns
it into a reply answers with the wrong one:

```
MISMATCH /foxtrot got='caught=no-such-thing:delta' want='caught=no-such-thing:foxtrot'
MISMATCH /bravo   got='caught=no-such-thing:charlie' want='caught=no-such-thing:bravo'
```

`/foxtrot` threw its own error, caught it one frame up, and read `/delta`'s
message out of the shared slot. In a router that maps a caught error onto a 404,
that is a good URL answered with somebody else's not-found — twice correct, then
a 404, then correct again, with nothing in the route table wrong.

Or the server simply stops:

```
concurrent-handler.ts:39:3: runtime error: integer overflow
```

That is the shared stack-depth counter going below zero, reported against a
`return` statement that has nothing to do with it. Its sibling is worse:

```
wt3.ts:3:17: runtime error: index out of bounds: index 131, len 128
```

— four threads pushing frames into one 128-entry trace buffer. Debug builds
catch that. A release build writes past the end of a global array.

Twelve rounds of twenty-four concurrent clients against the reproduction, fifty
requests each, killed the server in five of them.

## Scope

In scope:

- The per-call and per-throw runtime state a generated program keeps — current
  line and column, the throwing flag, the pending error message, the trace
  buffer, and the depth counter — becomes state of the thread that is running,
  not of the process.
- `Math.random`'s generator state and its lazy-init flag, for the same reason: a
  generator's state belongs to the stream drawing from it, and two handlers
  drawing at once were interleaving reads and writes of one Xoshiro state and
  racing the flag that says whether it has been seeded.
- Every thread source a program can have, not only the buffered HTTP server:
  the streaming server, `Worker.run`, and the async-fs pool all reach the same
  code.

Out of scope:

- `__sa_arena`, the string arena. It was the first suspect and it is not the
  problem: `std.heap.ArenaAllocator` in Zig 0.16 is lock-free and documents
  itself as thread-safe given a thread-safe child allocator, which
  `page_allocator` is. Wrapping it in a mutex would have cost every allocation
  in every program to fix nothing. See Notes.
- The open-file table (`__fd_table`), which is shared on purpose — a descriptor
  opened by one handler has to be readable by another — and would need a lock
  rather than a move onto the thread. Recorded, not fixed.
- Any state the *program* shares. A handler that mutates a module-level `Map` is
  racing, and that is the program's own bug; this spec is only about the state
  the compiler adds behind the program's back.

## Design

### D1 — `threadlocal`, not a lock

Each of these variables describes one call stack. A program with four worker
threads has four call stacks, so it should have four of each. `threadlocal` says
exactly that, and costs a register-offset load rather than a mutex — which
matters, because `__lumen_line` is written before *every* statement in a program
built with runtime locations.

A lock would be the wrong shape as well as the wrong price: there is nothing to
serialise. Two threads do not need to agree on which line is executing.

### D2 — `__lumen_color` stays global

It is written once, in `main`, before any thread exists, and never again. Making
it per-thread would leave every worker reading the default instead of the answer
`main` worked out, so worker output would lose its colour.

### D3 — no gate

The state moves onto the thread in every program, threaded or not. The
alternative — emit `threadlocal` only when the program needs a thread pool —
buys a single-threaded program nothing measurable and requires the gate to
enumerate every present and future way a thread can appear. `Worker.run` alone
is enough to make that enumeration a live hazard, and there is no cost to pay
for skipping it.

### D4 — the reproductions

Two, because the bug has two faces. A server whose handler allocates and splits
and concatenates, hammered by more clients than the box has cores, for the
crash. A server whose handler throws and catches its own error, for the wrong
answer. Both live in `examples/manual/` — a server never returns, so neither can
be a conformance case.

The conformance cases use `Worker.run`, which gives real OS threads inside a
program that terminates: four threads each throwing and catching twenty thousand
times, and asserting each one only ever caught its own.

## Success Criteria

1. Four threads each throwing and catching their own error twenty thousand
   times all count twenty thousand. Before, they counted around nineteen
   thousand nine hundred, and sometimes nineteen thousand three hundred.
2. Sixteen frames of unwinding on four threads at once does not walk off the end
   of the trace buffer or underflow the depth counter.
3. The concurrent-handler reproduction survives twenty-four rounds of 1,200
   concurrent requests with every response byte-exact. Before, it died in five
   rounds out of twelve.
4. Single-threaded stack traces, nested catches and rethrows are unchanged.
5. `zig build test` passes; the 468 and 455 manifests pass; the std-contrib
   suites pass.

## Notes

The report this started from named the string arena, and the arena is innocent.
Reading `std/heap/ArenaAllocator.zig` in the pinned Zig 0.16 shows a lock-free
implementation with acquire/release on the node list and an atomic bump of
`end_index`, and a header comment that says so. Proving it took removing the
frame bookkeeping from the generated Zig by hand and leaving everything else —
same arena, same allocations, same Debug safety checks — alone: 7,200 concurrent
requests, no failures. The allocator was never the thing.

Worth writing down separately, because it explains the observation that started
the report and is not this bug at all: five copies of the same server were
listening on port 8100. `addr.listen(io, .{ .reuse_address = true })` sets
`SO_REUSEPORT` as well as `SO_REUSEADDR` on Linux, so a second `lumen run` of a
server binds the same port instead of failing, and the kernel load-balances
connections between them. One of the five was an older build without the route
being asked for, so roughly one request in five got a 404 — "answered twice,
then 404, then worked again", exactly. Killing the stale process took a
30-request probe from six 404s to none, with no code change. A server that
silently shares its port with a stale copy of itself is its own problem, worth a
spec of its own.

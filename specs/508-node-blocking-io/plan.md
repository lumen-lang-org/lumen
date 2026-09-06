# Plan: 508 blocking I/O and threads on the Node target

## Where the reference behaviour lives (native, per surface)

Each Node-side function's contract is "match this exactly," not "invent a
shape" — read the native implementation first, every time.

- **`net.connect`/`Socket`**: `LumenSocket` struct, `src/lumen_runtime_net.zig:845`.
  Checker: `netCallType`, `src/lumen_check_stdlib.zig:826`; instance methods
  `socketMethod`, `src/lumen_check_methods.zig` (grep for `pub fn socketMethod`).
- **`http.request`/`http.stream`**: `LumenHttpStream` struct,
  `src/lumen_runtime_net.zig:95` (methods: `status:117`, `header:120`,
  `done:126`, `readLine:129`, `read:178`, `write:206`, `close:212`), built by
  `__httpStreamOpen:248`. Checker: `httpCallType`,
  `src/lumen_check_stdlib.zig:648`; instance methods `httpStreamMethod`,
  `src/lumen_check_methods.zig`.
- **`child_process.spawn`/`ChildProcess`**: `LumenChildProcess` struct,
  `src/lumen_runtime_os.zig:324` (`write:345`, `writeLine:353`, `readLine`
  and `close` follow — read the whole struct). Checker:
  `childProcessCallType`, `src/lumen_check_stdlib_os.zig:1367`.
- **`process.sleep`**: spec 475's own file for the exact "awake clock,
  zero/negative returns immediately" contract; native lowering is a
  straight blocking sleep call, no struct involved.
- **`Worker.run`**: checker `workerCallType`,
  `src/lumen_check_stdlib.zig:123` (the comment there states the exact
  restriction: zero-parameter function, `i32`/`i64`/`f64`/`bool` return
  only — the Node twin does not need to invent a wider contract).
- **`net.createServer`/`http.createServer`**: `__httpCreateServer`,
  `src/lumen_runtime_net.zig:461` and `:696` (two variants — read both to
  see why) — Node does not implement these; T010 makes the *emitter*
  reject them, so read only enough to write an accurate
  `E_TARGET_UNSUPPORTED` message, not to port the logic.

## Where the spike's lessons apply

`packages/node-runtime/spike/` is throwaway code kept for its findings, not
an API to import as-is. Before writing `lib/broker/`, re-read spec.md's
"Spike" section in full — it names two Node behaviours (`Atomics.waitAsync`
needs an explicit keep-alive; every socket listener must attach in the same
synchronous turn a socket is created) that are easy to silently regress
while promoting the prototype into real code, and a real gap
(`process.sleep`'s undershoot) that must be fixed this time, not carried
forward.

## Sequencing

T001–T003 (promote the broker) block everything else — do them first and
get `zig fmt`/`node --test` green before touching a single blocking
surface. T004 (`process.sleep`) is the smallest real surface end to end and
is the one to prove the promoted broker against before T005–T008, which
share its plumbing. T009 (`Worker.run`) and T010 (server rejection) have no
dependency on the broker at all and can happen in parallel with T004–T008
if useful. T011–T014 are the close-out gate, same shape as 502–507's.

## Verification

The gate is the same as every other Node-target spec (see this spec
folder's own conformance manifest once T011 writes it), plus
`node --test packages/node-runtime/tests/` for the broker's own unit tests
(none exist yet — T001 is also where they get written, covering at minimum
the two spike-found gotchas as regression tests: a broker under load with
nothing else scheduled must still answer, and a fast peer's data+EOF must
never be dropped).

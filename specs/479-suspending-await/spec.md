# Spec 479: `await` suspends, instead of driving the loop

## What is true today

Three programs, run against the current build. The output is verbatim.

**1. An `async function` runs eagerly, to completion, at the call site.**

```ts
async function waitFor(name: string, ms: int): Promise<string> {
  await pause(ms);
  console.log("finished " + name);
  return name;
}

async function main(): Promise<void> {
  let slow = waitFor("slow-300", 300);
  let quick = waitFor("quick-50", 50);
  console.log("both started");
  let a = await slow;
  let b = await quick;
  console.log("awaited " + a + " then " + b);
}
```

```
finished slow-300
finished quick-50
both started
awaited slow-300 then quick-50
  timer 50ms fired
  timer 300ms fired
```

Both calls finished before the line that says they were started. Nothing was
concurrent; the timers ran at drain, after the program had already decided
everything.

**2. Only the runtime can produce an unresolved promise.**

```
error: constructing a Promise with an executor is not supported yet —
use an `async function` (with `await`/`setTimeout`) or `Promise.resolve(v)`
```

`Promise.resolve` is resolved by definition, an `async function` returns
whatever its body returned — synchronously, per (1) — and `setTimeout` returns
`void`. So a Lumen program has no way to hand back a promise that will be
resolved later. Only `fs.*`, `Worker.*` and friends can.

**3. Which is why file I/O is the one thing that genuinely overlaps.**

```ts
let first = fs.readFile("/tmp/f1.txt");
let second = fs.readFile("/tmp/f2.txt");
let a = await first;
let b = await second;
```

```
start both / first started / second started / first done: aaaa / second done: bbbb
```

Both operations were submitted to io_uring before either was awaited. The
machinery for real concurrency is present and works — user code just cannot
reach it.

## The mechanism

Spec 022 chose this deliberately and says so: *"`await` drives the libuv event
loop until the awaited promise resolves."* In the current runtime:

```zig
fn driveUntil(ctx, done) void {
    while (!done(ctx)) { __xev_loop.run(.once) catch break; }
}
fn await_(self: *Self) T { … driveUntil … }
```

`await` does not yield. It pumps the loop **from inside the awaiting stack
frame** until its own promise resolves. Two consequences follow, and every
problem below is one of them:

- a function that is waiting still owns its stack, so its caller is blocked;
- a callback that the pump delivers runs *nested inside* the waiter's frame, so
  the waiter cannot return until that callback returns.

## What it costs

**A server accepts one connection.** `net.createServer` is an accept loop that
calls the handler inline. It cannot hand a session to the loop and continue,
because there is nothing to hand: a Lumen function cannot be parked. So
`serveSocketIO` — a `while (true) { socket.read() }` session that owns its
connection — serves exactly one client, and the second browser waits forever.
Every server built on `net` inherits this.

**A thread pool would only move the ceiling.** Dispatching accepted sockets to
a pool the way `http.createServer` does is one line and makes six connections
work. An HTTP handler holds its slot for milliseconds; a socket session holds it
for the length of a conversation. The failure moves from the second tab to the
seventh, which is strictly harder to diagnose.

**`Promise.all` cannot be what it looks like.** Whatever it does today, it
cannot be running things concurrently, because there is nothing to run.

## The change

1. Calling an `async function` **creates a task** and returns an unresolved
   promise. The body does not run at the call site.
2. `await` **suspends the current task** and returns control to the loop. It
   does not run the loop.
3. One loop, at the top of the program, resumes tasks whose promises have
   resolved and drains before exit.
4. `new Promise<T>(executor)` becomes constructible, because a program that can
   suspend can also resolve later. This is what lets a Lumen library wrap
   anything the runtime does not already wrap.

## Two ways to build it

**Stackless — async functions become state machines.** Each `await` splits the
body at a resume point; locals live in a heap frame. Small runtime, no stack
per task, tasks are cheap enough that a connection each is unremarkable. The
cost is in the emitter: every async function's body is rewritten, and Lumen's
existing shapes — `try`/`catch` across an await (spec 368), generic
specialisation (371), class methods (372) — each need a rule for how the split
interacts with them. This is the invasive one, and it is the one that scales.

**Stackful — each task gets a switchable stack.** `await` swaps stacks; the
emitter is untouched, so every existing async program keeps its shape and the
nine specs below keep passing unchanged. The cost is a stack per task: a
connection each is fine at hundreds, uncomfortable at tens of thousands, and
the stack size becomes a tuning knob nobody wants to own. Debuggers and
sanitisers dislike swapped stacks.

The recommendation is **stackful first**: it is the change that can be made
without touching how functions are emitted, it makes the servers correct, and
it can be replaced by the stackless transform later without changing a single
Lumen program. The one thing it must not do is present itself as unlimited.

## What must not break

Nine specs already depend on the current behaviour: 022, 047, 244, 286, 290,
368, 371, 372, 373. In particular:

- **022** documents the pump. Its text changes; its programs must still print
  what they print.
- **286** (`Promise.all`) is where suspension actually shows: with tasks, its
  arguments genuinely overlap. Any fixture asserting an order that came from
  sequential execution is asserting the bug.
- **368** (throw across await) is the sharp one. A throw does not cross a
  lambda here — the fixpoint pass cannot see through a function value — and a
  suspended task resumed from the loop is exactly that shape. Whatever
  suspension does, a throw inside a resumed task must still reach the `catch`
  that lexically encloses the `await`.
- **047** submits fs work to a thread pool and resolves on the main thread,
  deliberately, because `LumenPromise.resolve` is a non-atomic field write
  racing the main thread's poll. With tasks, "the main thread" needs a
  definition that survives the change.

## Conformance

`conformance/manifest.json`. The first case is the one that fails today:

- **`suspending-await.valid.two-waiters-interleave`** — two async calls with
  different deadlines, started before either is awaited; the shorter one
  finishes first, whichever is awaited first.
- **`suspending-await.valid.call-does-not-run-the-body`** — a line printed
  after the call appears before anything the body prints.
- **`suspending-await.valid.executor-resolves-later`** — `new Promise` with an
  executor that resolves from a timer.
- **`suspending-await.valid.throw-crosses-a-resume`** — a task that throws after
  suspending is caught by the `catch` around its `await` (368's rule, under
  suspension).
- **`suspending-await.valid.two-connections`** — two clients served at once by
  one `net.createServer`, which is the reason this spec exists.

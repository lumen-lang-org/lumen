# Feature Specification: Module-Level Bindings Visible And Initialized In `test` Blocks

## Problem

A module-level `let` or `const` is unusable from a `test` block. Referencing one
directly is a compile error; reaching one through a function compiles but reads
an uninitialized value.

Both are wrong, and the second is the dangerous one: it fails silently, so a
test can pass against garbage.

## Reproduction

### 1. Direct reference — compile error

```ts
let greeting = "hello";

test("module-level let inside a test block", () => {
  expect(greeting == "hello");
});
```

```
repro.ts:4:3: error: use of undeclared identifier '__lumen_0_greeting'
  4 |   expect(greeting == "hello");
    |   ^~~~~~
note: the native backend rejected this statement's generated code — likely a Lumen compiler bug; please report it
```

`const` behaves identically (`__lumen_1_c`). The mangled name comes from
`Checker.freshEmitName` (`src/lumen_check.zig:722`), which rewrites every
declaration to `__lumen_<id>_<name>`. The name reaches the generated Zig, but
nothing declares it in the scope the test body is emitted into.

### 2. Indirect reference — compiles, reads uninitialized memory

```ts
let g = "hello";
let n = 42;
function readG(): string { return g; }
function readN(): int { return n; }

test("what module-level values actually hold in a test", () => {
  console.log(`g=[${readG()}] n=${readN()}`);
  expect(true);
});
```

```
FAIL what module-level values actually hold in a test — Uncaught Error: integer does not fit in destination type
    at r5.ts:6
0 passed, 1 failed
```

`n` does not hold `42`. The initializer never ran.

### 3. The same program under `lumen run` is correct

```ts
let g = "hello";
function readG(): string { return g; }
console.log(`g=[${readG()}]`);
```

```
$ lumen run r6.ts
g=[hello]
```

So the defect is specific to how `lumen test` builds its entry point: top-level
statements — including the initializers for module-level bindings — are not
executed before test blocks run, and the bindings themselves are not in scope
for the emitted test bodies.

## Impact

Found while writing tests for the std-contrib `ai` package. Hoisting shared
fixture data to module scope is the obvious way to share a corpus across several
`test` blocks, and it is what a TypeScript developer will reach for first.

The workaround is to duplicate every fixture inside each test body, or to return
it from a function that builds it fresh on each call. Neither is discoverable
from the error message.

## Scope

In scope:

- Module-level `let` and `const` are in scope inside `test` block bodies.
- Their initializers run before any test block executes.
- Initialization happens once, not once per test.
- Initialization order follows declaration order, matching `lumen run`.

Out of scope:

- Per-test isolation or resetting module state between tests. A module-level
  `let` mutated by one test stays mutated for the next, exactly as it would
  across two calls in a `lumen run` program. Fixture isolation is a separate
  feature (`beforeEach`-style hooks), not part of this fix.
- Changing how `lumen run` orders top-level statements.
- Replaying an initializer that reads a module-level binding which stays a
  `main` local — a destructuring pattern (`const [a, b] = pair`), a
  multi-declarator group (`let p = 1, q = 2`), a `using` declaration, or a
  string/array accumulator. Those cannot be reconstructed inside
  `__lumenModuleInit`, so a promoted binding whose initializer depends on one
  is **rejected at compile time under `lumen test`** with a located error
  naming the binding, rather than emitted as an uninitialized global that a
  test would read as garbage. `lumen run`/`lumen compile` are unaffected — `main`
  still runs the initializer — so the same file runs correctly and is only
  refused when built for `zig test`. Promoting those binding forms themselves
  is a possible later slice.

## Success Criteria

1. Reproduction 1 compiles and passes.
2. Reproduction 2 prints `g=[hello] n=42` and passes.
3. A module-level `const` holding a record or an array is readable from a test
   block.
4. A module-level binding read by two different test blocks holds the same
   initialized value in both.
5. `zig build test` passes and `zig build conformance` is clean.

## Notes

The error message in reproduction 1 leaks the internal mangled name
(`__lumen_0_greeting`) to the user. Whatever the fix, a user-facing diagnostic
should never print `__lumen_<id>_<name>`; it should name the source-level
identifier. Worth handling as part of this slice since the same code path is
being touched.

## Implementation

A `test` block lowers to a top-level `test "..." { ... }` declaration — a
*sibling* of the generated `main`, not a statement inside it — and the test
runner never calls `main`. So both halves of the bug come from top-level
bindings living inside `main`:

- **Scope.** A top-level binding is lifted to a module global only when some
  function/method/constructor body reads it. `referencedByFunction` is now
  `referencedOutsideMain` and also scans `test` block bodies, so a binding read
  only from a test is lifted too. A promoted binding whose initializer reads
  another module-level binding drags that one up with it (transitively), so the
  initializer has everything it needs at module scope.
- **Initialization.** For a program that contains `test` blocks, the promoted
  bindings' assignments are also collected into a generated
  `__lumenModuleInit()` guarded by a `__lumen_module_inited` flag, and every
  emitted test block calls it first — after the `__io` wiring, so an initializer
  may itself do I/O. The guard makes it run once per binary, not once per test,
  and the assignments keep declaration order.

`main`'s body is emitted exactly as before and still holds the same statements
in the same order, so `lumen run` and `lumen compile` are unchanged. Programs
with no `test` block emit no init function and no call.

Diagnostics: `reportBackendFailure` now rewrites internal emit names
(`__lumen_7_greeting` -> `greeting`, `__lumen_user_main` -> `main`) out of every
backend message it forwards, so no user-facing error prints a generated
identifier.

## Limitations

Only module-level *initializers* run before test blocks — not arbitrary
top-level statements. A top-level `console.log`, a bare `counter = 2;`, or a
top-level call still does not execute under `lumen test`, so:

```ts
let a = 1;
a = 2;              // does not run under `lumen test`
test("t", () => { expect(a == 1); });   // 1 under test, 2 under run
```

The value is deterministic and initialized (never garbage), but it is the
declared value, not the post-statement one. Running the whole top-level body
would also start servers, spawn workers, and fire top-level `defer`s inside the
test binary; that is a separate decision from this fix.

Module-level destructuring (`const [a, b] = pair;`) and multi-declarator groups
(`let p = 1, q = 2;`) are still not lifted to module scope. That gap is not
test-specific — both already fail the same way under `lumen run` when a function
reads them — and is left for its own slice. The diagnostic for them now at least
names the source identifier.

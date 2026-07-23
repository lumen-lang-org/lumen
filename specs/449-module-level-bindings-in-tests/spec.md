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

# Spec 501: Running Lumen programs on Node.js

**Status**: Analysis and proposal (Draft) | **Date**: 2026-09-04

**Input**: A Lumen program is TypeScript syntax. Node.js runs TypeScript
syntax. So a Lumen program — Joule Code is the motivating one — should be
able to run on Node as well as compile to a native binary. This spec measures
how far that is from being true today, names every gap, and proposes the
shape of a Node target. It changes no compiler behaviour by itself.

## The short answer

Syntax is not the problem. Semantics and the standard library are, and the
compiler already has the information needed to bridge them. The right shape is
**a second backend in the compiler** (`lumen compile --target node`) that
emits JavaScript from the *typed* AST on top of a small Node runtime package,
not a type-stripping shim in front of Node. A shim can get the pure parts of a
program running in a day (measured below), but it cannot fix the two deep
gaps — byte strings and blocking I/O — because it does not know the types.

## What was measured

Joule Code (`joule-sh/code`, 290 `.ts` files, 35k lines, 1646 `test()` blocks
in 109 test files) was run against Node 22.22 with type stripping and a
prototype prelude that defines Lumen's global namespaces over Node's built-ins.
The probe scripts are in `probe/` and take a Joule checkout as input.

**Parse sweep** (`probe/sweep.mjs`: strip types with `node:module`, then
`node --check`):

| Files | Parse as JavaScript | Fail |
| --- | --- | --- |
| 290 | 285 | 5 |

All five failures are the same thing: a raw newline inside a `"..."` string
literal, which Lumen's lexer accepts and JavaScript's grammar does not
(`src/terminal/style.ts:57`, `renderer.ts`, and three test files).

**Test run** (`probe/run_tests.mjs`: each `*.test.ts` imported under the
prelude, its `test()` blocks executed):

| Test files | Loaded and all pass | Loaded, some fail | Did not load |
| --- | --- | --- | --- |
| 109 | 14 | 11 | 84 |

Of the 84 files that did not load:

| Cause | Files | What it is |
| --- | --- | --- |
| `https://` import | 37 | Node's ESM loader has no https scheme; Lumen fetches at build time (spec 012/486) |
| Type-only named import | 22 | `import { Message } from "./types.ts"` where `Message` is a type. Lumen elides it because it knows it is a type; a type stripper does not, and Node then fails on a missing export |
| Raw newline in a string | 25 | the five lexer-leniency files above, plus everything that imports them |
| FFI `declare function` | 2 | `tty_*` / `plat_*` resolve to a C object; nothing provides them under Node |

The 155 failing tests in files that did load are also a short list: `fs`
call shapes (`mkdirSync(p, true)` vs Node's options object), the two FFI
shims, and — the one that matters — `text.test.ts`: *"width is counted in
columns, not in the bytes UTF-8 spends on them"* fails because the program
decodes UTF-8 by hand from `charCodeAt`, which is correct on Lumen's strings
and wrong on JavaScript's.

The reading of these numbers: a Node target is not a rewrite of Joule. It is
one lexer decision, one loader, one runtime package, and two semantic
decisions the compiler must make on the program's behalf.

## Where Lumen and Node already agree

- Modules: relative imports with `.ts` extensions, named and default exports,
  module-level state (spec 346). This is exactly Node's ESM.
- Classes, closures, generics (erased), unions and narrowing, `Map`/`Set`,
  template literals, destructuring, optional chaining, `??`, `try`/`catch`/
  `finally`, `async`/`await`, `Promise.all`, `JSON`, `Math`, `Date.now`.
- `class` equality is reference equality in both (`lumen_emit.zig:740`: a
  non-string `==` lowers to Zig `==` on the instance pointer).
- Most of the stdlib is Node-shaped by design (plan.md, "Node-like Stdlib
  Decision"): `fs.*Sync`, `path`, `os`, `child_process.spawnSync`, `zlib`,
  `crypto.randomUUID`, `Buffer.from`, `url.parse`.

## Where they diverge, ranked by what it costs to bridge

### 1. A Lumen string is a sequence of bytes

`"é".length` is 2 in Lumen and 1 in JavaScript. `s[i]`, `charAt`,
`charCodeAt`, `fromCharCode`, `slice`, and `length` are all byte-indexed
(specs 144, 472). Programs are written to that: Joule has 59 `charCodeAt` and
57 `fromCharCode` sites, hand-rolled UTF-8 width counting, byte budgets like
`buffer.length > 64 * 1024`, and a WebSocket framer that builds frames by
concatenating `String.fromCharCode(byte)`.

No shim can fix this; a Lumen `string` value must be represented so that every
byte op is a JavaScript op with the same result. Two representations work:

- **Binary strings** — a JS string with one UTF-16 code unit per byte
  (`latin1`). Every byte-indexed operation is then the same JS operation,
  `+` concatenation works, `Map<string, T>` keys work, and only the boundary
  converts: `console.log`, `fs`, sockets, `JSON` (`Buffer.from(s, "latin1")`
  / `.toString("latin1")`). Cost: 2x memory for text, and a program that
  hands a Lumen string to a non-Lumen JS API without converting gets mojibake.
- **`Uint8Array`** — exact, but `+` and `==` stop being operators, every
  string expression needs a helper call, and generated code becomes hard to
  read and slow to write.

Binary strings are the recommendation. The emitter knows every expression's
type (`checked_operand_type` is already on every binary node), so it can
insert the boundary conversions itself and the user program never sees them.
The runtime's string literal must also be emitted as its UTF-8 bytes, which
the emitter already computes for Zig (`emitStrLit`, `lumen_emit.zig:108`).

### 2. I/O is blocking and threads are real

Lumen's I/O model is synchronous: `Socket.read()` blocks for the next chunk
(spec 054), `ChildProcess.readLine()` blocks (450), `http.stream(...).read()`
blocks (452), `process.sleep(ms)` blocks the thread (475), and
`net.createServer` runs each handler on its own OS thread (490).
`Worker.run(fn)` is a real thread (059). Joule is built on exactly this:
`while (true) { let chunk = socket.read(); ... }` is its WebSocket server, and
`process.sleep` appears 28 times in polling loops.

Node has one thread per isolate and no synchronous socket read. The options:

- **Rewrite every consumer to callbacks or `await`.** Rejected: it changes
  the signature of every function on the path, so it is not "the same
  program running on Node"; and Lumen's own `await` semantics (479) differ
  from JavaScript's, so it would not even be the same program under Lumen.
- **Synchronous shims where Node has them.** `fs`, `spawnSync`,
  `Atomics.wait` for `sleep`, `fs.readSync(fd)` on a tty. Covers the CLI
  path of Joule (`code.ts`), not the relay or the daemon.
- **One `worker_thread` per Lumen thread, blocking via `Atomics.wait`.**
  The main program, each `net.createServer` handler and each `Worker.run`
  body runs in its own `worker_threads` Worker; a blocking call posts a
  request to an I/O broker on the main thread and waits on a
  `SharedArrayBuffer` until the bytes arrive. This is the same shape Lumen's
  native runtime already has (a thread per handler, spec 490) and it keeps
  every user-facing signature. It is the recommendation. The prelude in
  `probe/` does `process.sleep` this way today.

### 3. Call shapes that differ from Node's

Each is a one-line adapter in the runtime package, but there are enough that
a package, not ad-hoc globals, is the right home:

| Lumen | Node | Note |
| --- | --- | --- |
| `process.platform()`, `arch()`, `pid()`, `stdout()` | properties | Lumen wraps them as calls (spec 033, 053) |
| `process.env("K")` / `process.env.K` | `process.env.K` | 439 rewrites the property form to the call |
| `argsCount()`, `arg(i)`, `process.argv()` | `process.argv` | |
| `fs.readFileSync(p)` → `string` | returns `Buffer` without an encoding | |
| `fs.mkdirSync(p, recursive: bool)` | `{ recursive }` options object | Joule calls it 67 times |
| `fs.statSync(p)` → `{ size, mtimeMs, isFile, isDirectory }` | `Stats` with methods | |
| `fs.readSync(fd, n)` → `string` | fills a caller buffer | |
| `crypto.randomBytes(n)` → hex string | `Buffer` | 035; `sha256(s)`, `sha1Bytes`, `base64Encode` are Lumen names |
| `child_process.spawnSync(cmd, args)` → `{ stdout, stderr, status }` strings | `Buffer`s, `status: null` on signal | |
| `child_process.spawn(cmd, args)` → `ChildProcess` with `readLine()` | event-based `ChildProcess` | blocking, see §2 |
| `http.request(url, method, body, headers)` → `{ status, body, headers }` | callback/streams | blocking |
| `net.connect(host, port)` → `Socket` with `read()` | event-based `Socket` | blocking |
| `time.monotonic()`, `time.now()` | `performance.now()`, `Date.now()` | |
| `Worker.run(fn)` → `Promise<scalar>` | `new Worker(file)` | 059 |
| `url.parse(s)` record | legacy `url.parse` / WHATWG `URL` | |

### 4. Lumen-only forms

- **FFI.** `declare function tty_isatty(fd: int): int;` with `// @link
  ./tty_shim.o`. On Node the same declaration must resolve to a JavaScript
  (or N-API) module. Proposal: a per-target link pragma, `// @link-node
  ./tty_shim.mjs`, whose named exports satisfy the declarations; the checker
  already knows the C-safe signature (009/023/024) and can type the JS side
  the same way. Joule's two shims are ~15 functions and all have Node
  equivalents (`tty.isatty`, `setRawMode`, `process.env`, `fs.chmodSync`),
  except the byte-with-timeout tty read, which needs the §2 broker.
- **`https://` imports** (012, 486). The compiler already fetches and
  inlines; the Node target emits the fetched module beside the others.
  Nothing to design, only to route.
- **`test()` / `expect()`** (008, 028). Lower to `node:test` and
  `node:assert`; `lumen test --target node` runs `node --test`. Tests in
  imported modules are stripped, as today.
- **`JSON.parse<T>`** (437, 483) validates the shape and names the missing
  field. The emitter has `T`; emit a validator per type, the same one that
  the Zig side generates, so a 400 on a bad body stays a 400.
- **Integer types.** `int`/`i32`/`i64` division truncates (spec 137:
  `@divTrunc`); JavaScript's does not. `layout.ts:52` computes
  `ms / 1000` into an `i64`. The emitter knows the operand types and emits
  `Math.trunc(a / b)` for integer division, `| 0` widening rules per 258,
  and `BigInt` only where an `i64` genuinely exceeds 2^53 (rare; a
  diagnostic first). Overflow: Zig panics in Debug and is undefined in
  ReleaseFast, so no program can depend on it; JS silently widens. Accept.
- **Raw newlines in string literals.** The lexer accepts them; nothing in
  the language relies on it. Emit them escaped, and add a warning so
  programs stay `tsc`-clean (this is a Joule fix of five lines regardless).
- **`embed()` / `embedDir()`** (458): inline at emit time, as today.
- **Decorators, `Class.*`** (455, 477): resolved at compile time and
  rewritten in place; the Node emitter sees the rewritten AST. Nothing to do.
- **`Ref<T>`** (024) is FFI-only; `defer`/`using` (007, 027) lower to
  `try/finally`.
- **Type-only imports.** The checker knows which imported names are types
  (451); the emitter drops them. This is the single largest cause of load
  failures in the probe and is free in a compiler backend.

## The proposal

### A. `lumen compile --target node <entry.ts>`

A second emitter beside `lumen_emit*.zig`, reading the same checked AST.
Output is a directory of ESM modules (one per source module, https modules
included) plus an entry `.mjs` that imports the runtime package. The wasm
target (030) is the precedent for "a flag selects a backend"; this one keeps
the front end and replaces only the last stage.

What the backend owns, because it needs type information:

1. Byte strings (§1): literals as bytes, boundary conversions at every
   stdlib call whose Node side takes or returns text.
2. Integer arithmetic (§4): truncating division, widening.
3. Type-only import elision and `export type` erasure.
4. `JSON.parse<T>` validators, `embed`, decorator rewrites.
5. `test()` → `node:test`.
6. FFI declarations → imports from the `@link-node` module.

### B. The runtime package

`packages/node-runtime/` (published later as `@lumen-lang/node`), plain
JavaScript with a `.d.ts`, containing every namespace in `website/stdlib/`
(`fs`, `path`, `os`, `process`, `crypto`, `child_process`, `net`, `http`,
`zlib`, `url`, `time`, `readline`, `assert`, `events`, `Buffer`, `Worker`),
in Lumen's call shapes (§3), over Node's built-ins. The broker for blocking
I/O (§2) lives here. `probe/lumen_node_prelude.mjs` is the seed: ~60 lines
already load 25 of Joule's test files.

### C. Loading without a compile step (optional, later)

A `node --import @lumen-lang/node/register` hook could resolve `https://`
imports from the compile cache and type-strip on the fly. It cannot do §1 or
§2, so it is a convenience for pure modules, not the product. Not in the
first slices.

## Slices

1. **Lexer**: warn on a raw newline in a string literal; the Zig target keeps
   accepting it. Joule fixes its five sites. (Small; unblocks 25 files.)
2. **Runtime package** with the §3 table, `fs`/`path`/`os`/`process`/
   `crypto`/`child_process.spawnSync`/`time`/`url`/`zlib`, and `test`/
   `expect`. Verified by running Joule's pure test files under it.
3. **`--target node` emitter**, pure language core: modules, type-only
   import elision, integer division, byte-string literals and boundary
   conversions, `test()` lowering. Conformance: the existing
   `specs/*/examples/valid` programs must print the same output under
   `node` as under the native binary — that corpus is the gate, the same way
   it is for the Zig target.
4. **Blocking I/O broker**: `process.sleep`, `net.connect`/`Socket.read`,
   `http.request`/`http.stream`, `child_process.spawn`/`readLine`,
   `net.createServer` handlers on worker threads, `Worker.run`.
5. **FFI**: `// @link-node <module.mjs>`; Joule's `tty` and `platform`
   shims get JavaScript twins.
6. **`lumen test --target node`** and a Joule `make node-test` target.

Slices 1–3 make `joule --version`, the terminal renderer, the protocol
codecs and the approval logic run on Node. Slice 4 is where the relay and
daemon come across.

## Success criteria

- **SC-001**: every `specs/*/examples/valid` program compiles with
  `--target node` and prints byte-identical output under `node` and natively.
- **SC-002**: Joule's `make test` suite runs under `lumen test --target
  node` with the same pass set as native, the `tty`/`platform` FFI files
  through their JavaScript twins.
- **SC-003**: `text.test.ts` ("width is counted in columns, not in the bytes
  UTF-8 spends on them") passes on Node — the byte-string decision holds.
- **SC-004**: the relay's WebSocket server (`vendor/websocket/server.ts`),
  unchanged, serves two concurrent clients under Node.
- **SC-005**: the native target is unchanged: `zig build conformance` is
  green.

## Not planned

| Item | Why |
| --- | --- |
| A bundler, npm dependencies, or `node_modules` resolution | V1 guardrail: no package manager. `https://` imports are already resolved by the compiler |
| Emitting TypeScript rather than JavaScript | the output is an artifact, like the generated Zig; `tsc` on it adds nothing the checker did not already do |
| Matching JavaScript's `await` ordering | Lumen's `await` semantics are its own (479); the Node target runs Lumen's semantics on Node, not the reverse |
| Browser target | the byte-string and broker decisions carry over, but `fs`, `net`, `child_process` do not exist there; a separate spec once the Node target exists |

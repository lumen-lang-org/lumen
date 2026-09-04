# Spec 503: the Node runtime package

**Status**: Draft | **Parent**: 501, slice 2

## Goal

A plain-JavaScript package, `packages/node-runtime/`, that provides every
global namespace a Lumen program expects — in Lumen's call shapes, with
Lumen's return types — over Node's built-ins. It is what generated
JavaScript (spec 504) imports, and on its own it lets a tsc-clean Lumen
module run under `node` today (the spec 501 probe loaded 25 of Joule's 109
test files with a 60-line sketch of it; that sketch is
`specs/501-node-runtime/probe/lumen_node_prelude.mjs` and is the seed).

## Surface

One ESM module per Lumen namespace, plus an `index.mjs` that installs them
on `globalThis` (a Lumen program never imports its stdlib). The reference for
each namespace is the checker: the names it accepts in
`src/lumen_check_stdlib.zig` and `src/lumen_check_stdlib_os.zig` are the
contract, and `website/stdlib/<ns>.html` documents each one's type.

| Module | Namespaces | Notes |
| --- | --- | --- |
| `process.mjs` | `process.*`, `argsCount`, `arg` | `platform()`, `arch()`, `pid()`, `cwd()`, `argv()` are calls; `env(k)` returns `string \| null`; `stdout()`/`stderr()`/`stdin()` return stream objects with `write`/`read`/`readLine`/`close`; `sleep(ms)` blocks via `Atomics.wait`; `exit`, `chdir`, `hrtime`, `memoryUsage`, `kill`, `umask` |
| `fs.mjs` | `fs.*` | `readFileSync(p, enc?)` returns a string; `mkdirSync(p, recursive?)`; `statSync` returns `{ size, mtimeMs, isFile, isDirectory }` fields; `readSync(fd, n)` returns a string; `readdirSync`, `rmSync`, `existsSync`, `rename`, `symlink`, `readlink`, `realpath`, `open/close`, `append`, `chmod`, `watch`, `createReadStream`/`createWriteStream` |
| `path.mjs`, `os.mjs` | `path.*`, `os.*` | `os.EOL()`, `devNull()`, `platform()` are calls |
| `crypto.mjs` | `crypto.*` | `randomBytes(n)` hex string; `randomBytesBuffer`; `sha256`/`sha1`/`sha1Bytes`; `base64Encode`/`Decode`; `hmacSync`, `encryptSync`/`decryptSync` (AES-256-GCM per 057), `encrypt`/`decrypt`/`randomKey` (467), `pbkdf2Sync`, `scryptSync`, `timingSafeEqual`, `createHash`/`createHmac` builders (060) |
| `child_process.mjs` | `spawnSync`, `spawn` | `spawnSync` returns strings and `status: -1` on signal; `spawn` returns a `ChildProcess` with `write`/`writeLine`/`readLine`/`close` — blocking, see 508 |
| `net.mjs`, `http.mjs` | `net.connect`, `createServer`, `http.request`, `stream`, `createServer`, `METHODS`, `STATUS_CODES` | blocking reads; see 508. `http.request` returns `{ status, body, headers }` |
| `zlib.mjs`, `url.mjs`, `time.mjs`, `readline.mjs`, `assert.mjs`, `events.mjs` | as documented | `time.now()`/`monotonic()` are `i64` ms |
| `buffer.mjs` | `Buffer` | Lumen's `Buffer` (056): `from`, `alloc`, `length`, `toString(enc)`, `at`, `slice`, `equals` |
| `worker.mjs` | `Worker.run(fn)` | a `worker_threads` Worker per call for scalar-returning functions; see 508 for the shared-state limit |
| `test.mjs` | `test`, `expect` | `test(name, fn)` registers with `node:test`; `expect(bool)`, `expect(a).toBe(b)`, `.toEqual(b)` map to `node:assert` |
| `lang.mjs` | `defer`, `Error` helpers, string byte helpers | the helpers spec 505's emitted code calls: `__bytes(s)`, `__text(s)`, `__divInt(a, b)` |

## Requirements

- **FR-001**: every name the checker accepts under a namespace exists in the
  package with the documented signature; a missing one is a bug, not a
  "not supported on Node". The list is generated, not hand-kept: a script
  (`tools/stdlib_names.py`) extracts the accepted names from the two checker
  files and the package's test asserts each is exported.
- **FR-002**: string arguments and results cross the boundary as Lumen byte
  strings (spec 505): the package converts with `Buffer.from(s, "latin1")`
  on the way in and `.toString("latin1")` on the way out, and never with
  `utf8`. Until 505 lands the package ships a `LUMEN_STRINGS=utf16` switch
  for running hand-written tsc-clean modules; the switch is removed by 505.
- **FR-003**: the package has no dependencies and no build step.
- **FR-004**: the package installs on `globalThis` only when imported as
  `@lumen-lang/node/globals`; importing a namespace module directly installs
  nothing, so it can be used from ordinary JavaScript too.
- **FR-005**: every function's behaviour on failure matches the native
  runtime's documented fallback (`""`, `-1`, `null`, or a throw), taken from
  the spec that introduced it, not from Node's.

## Success criteria

- **SC-001**: the name-coverage test passes for every namespace.
- **SC-002**: `node --import @lumen-lang/node/globals` runs the
  `specs/*/examples/valid` programs that use only tsc-clean syntax and the
  synchronous stdlib, printing what the native binary prints (list pinned in
  `tests/corpus.txt`; the initial list is produced by running them all and
  recording which pass).
- **SC-003**: Joule's probe (`specs/501-node-runtime/probe/run_tests.mjs`)
  with this package in place of the prelude loads at least 40 of 109 files
  (the 25 raw-newline files stay out until Joule fixes them) and every
  `fs`/`path`/`crypto`/`spawnSync` failure it reported is gone.

## Not planned

| Item | Why |
| --- | --- |
| TypeScript source for the package | it is a runtime for generated code; a `.d.ts` is enough for editors |
| Publishing to npm | after 504 works end to end; until then it is consumed by path |

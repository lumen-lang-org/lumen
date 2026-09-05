# @lumen-lang/node

Lumen's standard library on Node: every global namespace a Lumen program
expects (`fs`, `path`, `os`, `process`, `crypto`, `child_process`, `net`,
`http`, `zlib`, `url`, `time`, `readline`, `assert`, `EventEmitter`,
`Buffer`, `Worker`, `test`/`expect`, `defer`, `argsCount`/`arg`) in Lumen's
call shapes and with Lumen's return types, over Node's built-ins. Plain
JavaScript, no dependencies, no build step (spec 503).

```sh
node --import /path/to/packages/node-runtime/globals.mjs program.ts
```

installs the namespaces on `globalThis` and grafts Lumen's `process.*` calls
(`process.platform()`, `process.env("HOME")`, `process.stdout()`) onto
Node's `process`. Importing the package itself, or one of its `lib/*.mjs`
modules, installs nothing and gives the same functions as exports, so they
can be used from ordinary JavaScript too.

## What is Lumen-shaped here

- The reference for each namespace is the compiler's checker; the names it
  accepts are extracted by `tools/stdlib_names.py` into `tests/names.json`,
  and `tests/names.test.mjs` asserts each one is exported.
- Failure behaviour follows the native runtime, not Node's: `fs` calls that
  throw natively throw here with the same message shape (`cannot read
  'p': ENOENT`), and the rest fall back to `""`, `-1`, `false`, `[]` or a
  zero-filled record. `assert.*` ends the program, uncatchably.
- Constants are calls: `os.EOL()`, `path.sep()`, `Math.PI()`,
  `http.METHODS()`. Under the globals `Math` and `Number` are overlays
  whose constants read as numbers and as calls.
- `Buffer` is Lumen's (spec 056): `from`, `alloc`, `length`, `toString`,
  `at`, `slice`, `equals`, over a `Uint8Array`.
- `test(name, fn)` registers with `node:test` under `node --test`; under a
  plain `node` run the blocks do not execute, as with `lumen run`.
  `LUMEN_TEST=inline` runs them at declaration and tallies into
  `globalThis.__t`.

## Strings

A Lumen string is a sequence of bytes. The package represents it as a
JavaScript string with one code unit per byte (Node's `latin1`) and
converts at the boundary with `Buffer.from(s, "latin1")` on the way in and
`.toString("latin1")` on the way out — never `utf8` (spec 505). Until the
Node emitter lands, `LUMEN_STRINGS=utf16` switches the boundary to text so
hand-written `.ts` modules with ordinary JavaScript strings run; spec 505
removes the switch.

## Not yet: blocking I/O

`net.connect`, `net.createServer`, `http.request`/`get`/`stream`/
`createServer`, `child_process.spawn` and `Worker.run` block or thread
natively. They throw an `Error` naming spec 508, which adds the I/O
broker, so a program that reaches them fails by name rather than hanging.

## Tests

```sh
node --test packages/node-runtime/tests/
```

`tests/corpus.txt` lists the `specs/*/examples/valid` programs that print
under `node` what the native binary prints; `tests/corpus.test.mjs` checks
them against `zig-out/bin/lumen`.

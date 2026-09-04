# Plan: 503 Node runtime package

## Technical context

- Runtime: Node 22.18+ (type stripping on by default is not needed by the
  package itself, only by the probe).
- Location: `packages/node-runtime/` (beside `packages/context-index`, which
  is the existing Node-wrapper precedent).
- Tests: `node --test packages/node-runtime/tests/` — no framework.
- Reference implementations to read before writing each module: the Zig
  runtime preludes `src/lumen_runtime_os.zig` (process, stdio, crypto),
  `src/lumen_runtime_fs.zig`, `src/lumen_runtime_net.zig`, and the spec that
  introduced each function (numbers in `docs/CODEMAP.md`).

## Layout

```
packages/node-runtime/
├── package.json          # "name": "@lumen-lang/node", "type": "module", exports map
├── index.mjs             # re-exports every namespace
├── globals.mjs           # installs them on globalThis
├── lumen.d.ts            # types for editors (mirrors the root lumen.d.ts, extended)
├── lib/{process,fs,path,os,crypto,child_process,net,http,zlib,url,time,readline,assert,events,buffer,worker,test,lang}.mjs
├── tests/names.test.mjs  # every checker-accepted name is exported
├── tests/*.test.mjs      # one per module, behaviour pinned to the native spec
└── tests/corpus.txt      # examples/valid programs that must print identically
```

## Approach

1. Generate the name list: `tools/stdlib_names.py` reads the string literals
   compared against `call.name`/`mc.name` in the two checker files (the
   probe did this by grep; make it a script and commit its output as
   `tests/names.json` so the test does not need Python).
2. Write `process`, `fs`, `path`, `os`, `time`, `crypto`, `child_process.spawnSync`,
   `zlib`, `url`, `assert`, `buffer`, `test` first — the synchronous set.
   Each function reads its spec before it is written.
3. Add `globals.mjs` and run the `examples/valid` corpus under
   `node --import`; record which programs pass in `tests/corpus.txt`.
4. Stub the blocking set (`net`, `http`, `spawn`, `readline`, `Worker`) with
   a clear `Error("... needs the I/O broker, spec 508")` so a program that
   reaches them fails loudly and by name.
5. Point Joule's probe at the package and record the new numbers in the
   spec's success criteria.

## Risks

- `process` is not replaceable wholesale in Node; `platform`, `arch`, `pid`,
  `stdout` must be redefined with `Object.defineProperty` (the probe shows
  how, including keeping `console.log` working through a Proxy).
- `fs.readSync(fd, n)` on a tty blocks correctly; on a pipe it also blocks,
  which is the Lumen behaviour. `process.sleep` via `Atomics.wait` needs a
  `SharedArrayBuffer`, available in Node without flags.
